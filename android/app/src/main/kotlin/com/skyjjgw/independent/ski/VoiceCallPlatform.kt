package com.skyjjgw.independent.ski

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Bundle
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.media.MediaRecorder
import android.speech.RecognitionListener
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import android.speech.tts.TextToSpeech
import android.speech.tts.UtteranceProgressListener
import io.flutter.embedding.android.FlutterActivity
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.util.Locale
import android.media.MediaPlayer
import android.media.AudioAttributes
import java.io.File

/** Session-scoped system speech adapter. Audio and transcripts are never logged. */
class VoiceCallPlatform(private val activity: FlutterActivity) {
    private lateinit var channel: MethodChannel
    private var recognizer: SpeechRecognizer? = null
    private var tts: TextToSpeech? = null
    private var ttsReady = false
    private var listening = false
    private var epoch = 0
    private var utterance: String? = null
    private var permissionResult: MethodChannel.Result? = null
    private var permissionAction: (() -> String)? = null
    private val main=Handler(Looper.getMainLooper())
    private var recorder: MediaRecorder? = null
    private var recordingFile: File? = null
    private var recordingProbe: Runnable? = null
    private val recordings=mutableSetOf<String>()
    private val preparing = mutableListOf<MethodChannel.Result>()
    private var speechEpoch = 0
    private var audioEpoch = 0
    private var player: MediaPlayer? = null
    private var audioFile: File? = null
    fun register(messenger: BinaryMessenger) {
        channel = MethodChannel(messenger, "skivu/voice_call")
        channel.setMethodCallHandler { call, result ->
            try {
                when(call.method) {
                    "prepare" -> {
                        if(call.argument<Boolean>("systemTts") == false) result.success(null)
                        else prepare(result)
                    }
                    "recognitionStatus" -> result.success(mapOf("systemAvailable" to SpeechRecognizer.isRecognitionAvailable(activity),"onDeviceAvailable" to (Build.VERSION.SDK_INT>=31&&SpeechRecognizer.isOnDeviceRecognitionAvailable(activity)),"microphoneGranted" to (activity.checkSelfPermission(Manifest.permission.RECORD_AUDIO)==PackageManager.PERMISSION_GRANTED)))
                    "listen", "record" -> {
                        val arguments=call.arguments as? Map<*,*> ?: emptyMap<Any,Any>()
                        val start:()->String={if(call.method=="record"){record(arguments);"recording"}else{listen(arguments);"listening"}}
                        if(activity.checkSelfPermission(Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
                            if(call.argument<Boolean>("requestPermission") == true && permissionResult == null) {
                                permissionResult = result;permissionAction=start
                                activity.requestPermissions(arrayOf(Manifest.permission.RECORD_AUDIO), 7462)
                            } else result.success("permission_required")
                        } else result.success(start())
                    }
                    "finishListening" -> { recognizer?.stopListening(); result.success(null) }
                    "finishRecording" -> { finishRecording(); result.success(null) }
                    "discardRecording" -> { call.argument<String>("path")?.let{path->if(recordings.remove(path))File(path).delete()};result.success(null) }
                    "stopListening" -> { stopListening(); result.success(null) }
                    "speak" -> {
                        stopListening()
                        check(ttsReady) { "系统朗读引擎尚未就绪，请稍后重试或检查语言包。" }
                        releaseAudio()
                        tts?.setSpeechRate((call.argument<Double>("speed") ?: 1.0).toFloat().coerceIn(0.5f, 2f))
                        val voiceName = call.argument<String>("voice").orEmpty()
                        if(voiceName.isNotBlank()) {
                            val voice = tts?.voices?.firstOrNull { it.name == voiceName }
                            require(voice != null) { "未找到该系统音色，请检查音色 ID，或留空使用默认。" }
                            tts?.voice = voice
                        } else tts?.language = Locale.SIMPLIFIED_CHINESE
                        val text = call.argument<String>("text") ?: ""
                        val id = "skivu-${System.nanoTime()}"
                        val chunks = text.chunked(TextToSpeech.getMaxSpeechInputLength() - 16)
                        require(chunks.isNotEmpty())
                        utterance = "$id-${chunks.lastIndex}"
                        chunks.forEachIndexed { index, chunk ->
                            check(tts?.speak(chunk, if(index == 0) TextToSpeech.QUEUE_FLUSH else TextToSpeech.QUEUE_ADD, null, "$id-$index") == TextToSpeech.SUCCESS)
                        }
                        result.success(null)
                    }
                    "playAudio" -> playAudio(call.argument<ByteArray>("bytes"), result)
                    "stop" -> { pause(); result.success(null) }
                    "close" -> { close(); result.success(null) }
                    else -> result.notImplemented()
                }
            } catch(failure: Exception) {
                result.error("VOICE_UNAVAILABLE", failure.message ?: "系统语音暂不可用。", null)
            }
        }
    }
    private fun emit(name: String, data: Map<String, Any> = emptyMap()) {
        activity.runOnUiThread { channel.invokeMethod(name, data) }
    }
    private fun prepare(result: MethodChannel.Result) {
        if(ttsReady) { result.success(null); return }
        preparing.add(result)
        if(tts != null) return
        val generation = ++speechEpoch
        tts = TextToSpeech(activity) { status ->
            activity.runOnUiThread {
                if(generation == speechEpoch) {
                    ttsReady = status == TextToSpeech.SUCCESS
                    if(ttsReady) tts?.language = Locale.SIMPLIFIED_CHINESE
                    val pending = preparing.toList(); preparing.clear()
                    pending.forEach {
                        if(ttsReady) it.success(null)
                        else it.error("VOICE_UNAVAILABLE", "系统朗读引擎初始化失败，请检查系统语音服务。", null)
                    }
                    if(!ttsReady) { tts?.shutdown(); tts = null }
                }
            }
        }
        tts?.setOnUtteranceProgressListener(object : UtteranceProgressListener() {
            override fun onStart(id: String?) {}
            override fun onDone(id: String?) { if(id == utterance) { utterance = null; emit("ttsDone") } }
            @Deprecated("Deprecated in Java")
            override fun onError(id: String?) { if(id == utterance) { utterance = null; emit("ttsError") } }
        })
    }
    private fun releaseAudio() {
        player?.release(); player = null
        audioFile?.delete(); audioFile = null
    }
    private fun playAudio(bytes: ByteArray?, result: MethodChannel.Result) {
        require(bytes != null && bytes.isNotEmpty()) { "音频为空。" }
        pause()
        val generation = audioEpoch
        Thread {
            var file: File? = null
            try {
                val saved = File.createTempFile("skivu-voice-", ".audio", activity.cacheDir)
                file = saved
                saved.writeBytes(bytes)
                activity.runOnUiThread {
                    if(generation != audioEpoch) { saved.delete(); result.success(null) }
                    else try {
                        val next = MediaPlayer()
                        player = next; audioFile = saved
                        next.setAudioAttributes(AudioAttributes.Builder().setContentType(AudioAttributes.CONTENT_TYPE_SPEECH).setUsage(AudioAttributes.USAGE_MEDIA).build())
                        next.setDataSource(saved.absolutePath)
                        next.setOnPreparedListener { if(player === next && generation == audioEpoch) next.start() }
                        next.setOnCompletionListener { if(player === next) { releaseAudio(); emit("ttsDone") } }
                        next.setOnErrorListener { _, _, _ ->
                            if(player === next) { releaseAudio(); emit("ttsError") }; true
                        }
                        next.prepareAsync()
                        result.success(null)
                    } catch(_: Exception) { releaseAudio(); result.error("VOICE_UNAVAILABLE", "音频无法播放，请检查返回的音频格式。", null) }
                }
            } catch(_: Exception) {
                file?.delete()
                activity.runOnUiThread { result.error("VOICE_UNAVAILABLE", "音频临时文件创建失败。", null) }
            }
        }.start()
    }
    private fun listen(options:Map<*,*>) {
        stopListening()
        check(SpeechRecognizer.isRecognitionAvailable(activity)) { "本机没有语音识别服务；请在语音设置中选择自定义识别服务，或安装系统语音识别服务。" }
        val generation = ++epoch
        val onDevice=options["preferOnDevice"]==true&&Build.VERSION.SDK_INT>=31&&SpeechRecognizer.isOnDeviceRecognitionAvailable(activity)
        val next = if(onDevice&&Build.VERSION.SDK_INT>=31)SpeechRecognizer.createOnDeviceSpeechRecognizer(activity)else SpeechRecognizer.createSpeechRecognizer(activity)
        recognizer = next; listening = true
        fun current() = epoch == generation && listening
        next.setRecognitionListener(object : RecognitionListener {
            override fun onReadyForSpeech(params: Bundle?) {}
            override fun onBeginningOfSpeech() { if(current()) emit("speech") }
            override fun onRmsChanged(rmsdB: Float) { if(current()) emit("level", mapOf("value" to rmsdB.coerceAtLeast(0f).toDouble())) }
            override fun onBufferReceived(buffer: ByteArray?) {}
            override fun onEndOfSpeech() { if(current()) emit("transcribing") }
            override fun onError(error: Int) { if(current()) {listening = false; emit("recognitionError", mapOf("code" to error))} }
            override fun onResults(results: Bundle?) {
                if(!current()) return
                listening = false
                val text = results?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)?.firstOrNull() ?: ""
                if(text.isBlank()) emit("recognitionError", mapOf("code" to 7)) else emit("result", mapOf("text" to text))
            }
            override fun onPartialResults(partialResults: Bundle?) { if(current()) emit("partial", mapOf("text" to (partialResults?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)?.firstOrNull() ?: ""))) }
            override fun onEvent(eventType: Int, params: Bundle?) {}
        })
        next.startListening(Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH)
            .putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
            .putExtra(RecognizerIntent.EXTRA_LANGUAGE, options["language"]?.toString()?.ifBlank{null} ?: Locale.getDefault().toLanguageTag())
            .putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, true))
    }
    @Suppress("DEPRECATION")
    private fun record(options:Map<*,*>){
        stopListening()
        val file=File.createTempFile("skivu-recognition-", ".m4a", activity.cacheDir)
        val next=if(Build.VERSION.SDK_INT>=31)MediaRecorder(activity)else MediaRecorder()
        try{
            next.setAudioSource(MediaRecorder.AudioSource.VOICE_RECOGNITION)
            next.setOutputFormat(MediaRecorder.OutputFormat.MPEG_4)
            next.setAudioEncoder(MediaRecorder.AudioEncoder.AAC)
            next.setAudioSamplingRate(44100);next.setAudioEncodingBitRate(96000);next.setAudioChannels(1)
            next.setOutputFile(file.absolutePath);next.prepare();next.start()
            recorder=next;recordingFile=file;recordings.add(file.absolutePath)
            val generation=epoch;val silence=(options["silenceMillis"] as? Number)?.toLong()?:1200L
            var heard=false;var lastVoice=SystemClock.uptimeMillis()
            val probe=object:Runnable{override fun run(){
                if(recorder!==next||generation!=epoch)return
                val amplitude=runCatching{next.maxAmplitude}.getOrDefault(0)
                emit("level", mapOf("value" to (amplitude/3276.8)))
                if(amplitude>900){lastVoice=SystemClock.uptimeMillis();if(!heard){heard=true;emit("speech")}}
                if(heard&&silence>0&&SystemClock.uptimeMillis()-lastVoice>=silence){finishRecording();return}
                main.postDelayed(this,100)
            }}
            recordingProbe=probe;main.postDelayed(probe,100)
        }catch(e:Exception){next.release();file.delete();throw IllegalStateException("麦克风录音启动失败，请检查权限、系统麦克风开关或其他应用是否正在收音。",e)}
    }
    private fun finishRecording(){
        val next=recorder?:return;val file=recordingFile?:return
        recordingProbe?.let{main.removeCallbacks(it)};recordingProbe=null;recorder=null;recordingFile=null
        try{next.stop();next.release();check(file.length()>0){"录音没有有效内容，请说话后重新结束。"};emit("recorded",mapOf("path" to file.absolutePath,"bytes" to file.length(),"mime" to "audio/mp4"))}
        catch(_:Exception){runCatching{next.release()};recordings.remove(file.absolutePath);file.delete();emit("recognitionError",mapOf("code" to 3))}
    }
    private fun stopListening() {
        // A canceled draft must not start capturing later when an already-open
        // Android permission dialog finally returns its result.
        permissionAction=null
        permissionResult?.success("permission_required");permissionResult=null
        ++epoch; listening = false; recognizer?.cancel(); recognizer?.destroy(); recognizer = null
        recordingProbe?.let{main.removeCallbacks(it)};recordingProbe=null
        recorder?.let{runCatching{it.stop()};it.release()};recorder=null
        recordingFile?.let{recordings.remove(it.absolutePath);it.delete()};recordingFile=null
    }
    fun permissionResult(requestCode: Int, grantResults: IntArray) {
        if(requestCode != 7462) return
        val result = permissionResult ?: return
        permissionResult = null
        val start=permissionAction;permissionAction=null
        try {
            if(grantResults.firstOrNull() == PackageManager.PERMISSION_GRANTED) {result.success(start?.invoke()?:"permission_required")}
            else result.success("permission_required")
        } catch(failure: Exception) {result.error("VOICE_UNAVAILABLE", failure.message, null)}
    }
    fun pause() { ++audioEpoch; releaseAudio(); stopListening(); utterance = null; tts?.stop() }
    fun close() {
        pause(); ++speechEpoch; tts?.shutdown(); tts = null; ttsReady = false
        preparing.forEach { it.error("VOICE_UNAVAILABLE", "语音已关闭。", null) }; preparing.clear()
        permissionResult?.success("permission_required"); permissionResult = null;permissionAction=null
        recordings.toList().forEach{File(it).delete()};recordings.clear()
    }
}
