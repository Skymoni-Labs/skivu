import 'package:flutter/services.dart';

/// A draft, call or preview owns the channel until its native cleanup finishes.
/// An inactive settings page cannot replace a live microphone's event handler.
class VoiceChannelLease {
  static final Map<String, Object> _owners = {};
  static bool owns(MethodChannel channel, Object owner) =>
      identical(_owners[channel.name], owner);
  static void claim(
    MethodChannel channel,
    Object owner,
    Future<dynamic> Function(MethodCall) events,
  ) {
    final active = _owners[channel.name];
    if (active != null && !identical(active, owner)) {
      throw const FormatException('已有语音会话正在使用麦克风或播放，请先结束该会话。');
    }
    _owners[channel.name] = owner;
    channel.setMethodCallHandler(events);
  }

  static void release(MethodChannel channel, Object owner) {
    if (!owns(channel, owner)) return;
    _owners.remove(channel.name);
    channel.setMethodCallHandler(null);
  }
}
