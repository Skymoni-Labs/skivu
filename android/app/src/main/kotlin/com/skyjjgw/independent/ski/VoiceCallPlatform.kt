package com.skyjjgw.independent.ski

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Bundle
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
                    "listen" -> {
                        if(activity.checkSelfPermission(Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
                            if(call.argument<Boolean>("requestPermission") == true && permissionResult == null) {
                                permissionResult = result
                                activity.requestPermissions(arrayOf(Manifest.permission.RECORD_AUDIO), 7462)
                            } else result.success("permission_required")
                        } else { listen(); result.success("listening") }
                    }
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
        require(bytes != null && bytes.isNotEmpty() && bytes.size <= 10 * 1024 * 1024) { "音频为空或超过 10 MB。" }
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
    private fun listen() {
        check(SpeechRecognizer.isRecognitionAvailable(activity)) { "本机没有语音识别服务；请安装系统语音服务，或在更多中输入文字。" }
        stopListening()
        val generation = ++epoch
        val next = SpeechRecognizer.createSpeechRecognizer(activity)
        recognizer = next; listening = true
        fun current() = epoch == generation && listening
        next.setRecognitionListener(object : RecognitionListener {
            override fun onReadyForSpeech(params: Bundle?) {}
            override fun onBeginningOfSpeech() { if(current()) emit("speech") }
            override fun onRmsChanged(rmsdB: Float) { if(current()) emit("level", mapOf("value" to rmsdB.coerceAtLeast(0f).toDouble())) }
            override fun onBufferReceived(buffer: ByteArray?) {}
            override fun onEndOfSpeech() {}
            override fun onError(error: Int) { if(current()) {listening = false; emit("recognitionError", mapOf("code" to error))} }
            override fun onResults(results: Bundle?) {
                if(!current()) return
                listening = false
                val text = results?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)?.firstOrNull() ?: ""
                if(text.isBlank()) emit("recognitionError", mapOf("code" to 7)) else emit("result", mapOf("text" to text))
            }
            override fun onPartialResults(partialResults: Bundle?) {}
            override fun onEvent(eventType: Int, params: Bundle?) {}
        })
        next.startListening(Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH)
            .putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
            .putExtra(RecognizerIntent.EXTRA_LANGUAGE, "zh-CN")
            .putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, false))
    }
    private fun stopListening() { ++epoch; listening = false; recognizer?.cancel(); recognizer?.destroy(); recognizer = null }
    fun permissionResult(requestCode: Int, grantResults: IntArray) {
        if(requestCode != 7462) return
        val result = permissionResult ?: return
        permissionResult = null
        try {
            if(grantResults.firstOrNull() == PackageManager.PERMISSION_GRANTED) {listen(); result.success("listening")}
            else result.success("permission_required")
        } catch(failure: Exception) {result.error("VOICE_UNAVAILABLE", failure.message, null)}
    }
    fun pause() { ++audioEpoch; releaseAudio(); stopListening(); utterance = null; tts?.stop() }
    fun close() {
        pause(); ++speechEpoch; tts?.shutdown(); tts = null; ttsReady = false
        preparing.forEach { it.error("VOICE_UNAVAILABLE", "语音已关闭。", null) }; preparing.clear()
        permissionResult?.success("permission_required"); permissionResult = null
    }
}
