import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum GroupReplyRule { manual, mentions, roundRobin, automatic }

extension GroupReplyLabel on GroupReplyRule {
  String get label => switch (this) {
    GroupReplyRule.manual => '手动指定角色',
    GroupReplyRule.mentions => '仅回应 @ 的角色',
    GroupReplyRule.roundRobin => '按成员顺序轮流回复',
    GroupReplyRule.automatic => '自动选择回复角色',
  };
}

class SocialConfig {
  const SocialConfig({
    this.wechatPosts = false,
    this.wechatComments = false,
    this.qqPosts = false,
    this.qqComments = false,
    this.roleIds = const [],
    this.intervalMinutes = 180,
    this.dailyLimit = 3,
    this.groupRule = GroupReplyRule.manual,
    this.groupMembers = const [],
    this.groupMaxReplies = 1,
    this.groupHistoryLimit = 20,
  });
  final bool wechatPosts, wechatComments, qqPosts, qqComments;
  final List<String> roleIds, groupMembers;
  final int intervalMinutes, dailyLimit, groupMaxReplies, groupHistoryLimit;
  final GroupReplyRule groupRule;
  bool posts(String channel) => channel == 'qq' ? qqPosts : wechatPosts;
  bool comments(String channel) =>
      channel == 'qq' ? qqComments : wechatComments;
  Map<String, dynamic> toJson() => {
    'wechatPosts': wechatPosts,
    'wechatComments': wechatComments,
    'qqPosts': qqPosts,
    'qqComments': qqComments,
    'roleIds': roleIds,
    'intervalMinutes': intervalMinutes,
    'dailyLimit': dailyLimit,
    'groupRule': groupRule.name,
    'groupMembers': groupMembers,
    'groupMaxReplies': groupMaxReplies,
    'groupHistoryLimit': groupHistoryLimit,
  };
  factory SocialConfig.fromJson(Map<String, dynamic> raw) {
    List<String> ids(String key) =>
        (raw[key] is List ? raw[key] as List : const [])
            .whereType<String>()
            .where((s) => s.isNotEmpty && s.length <= 100)
            .toSet()
            .take(100)
            .toList();
    int number(String key, int fallback, int min, int max) =>
        raw[key] is int ? (raw[key] as int).clamp(min, max) : fallback;
    int choice(String key, int fallback, List<int> options) =>
        options.contains(raw[key]) ? raw[key] as int : fallback;
    return SocialConfig(
      wechatPosts: raw['wechatPosts'] == true,
      wechatComments: raw['wechatComments'] == true,
      qqPosts: raw['qqPosts'] == true,
      qqComments: raw['qqComments'] == true,
      roleIds: ids('roleIds'),
      intervalMinutes: choice('intervalMinutes', 180, [
        30,
        60,
        180,
        360,
        720,
        1440,
      ]),
      dailyLimit: number('dailyLimit', 3, 1, 10),
      groupRule:
          GroupReplyRule.values
              .where((v) => v.name == raw['groupRule'])
              .firstOrNull ??
          GroupReplyRule.manual,
      groupMembers: ids('groupMembers'),
      groupMaxReplies: number('groupMaxReplies', 1, 1, 6),
      groupHistoryLimit: choice('groupHistoryLimit', 20, [5, 10, 20, 50, 100]),
    );
  }
}

class SocialSettings extends ChangeNotifier {
  static const storageKey = 'skivu.social-settings.v1';
  SocialConfig value = const SocialConfig();
  String? error;
  Future<void> _writes = Future.value();
  Future<void> restore() async {
    try {
      final raw = (await SharedPreferences.getInstance()).getString(storageKey);
      if (raw != null)
        value = SocialConfig.fromJson(
          Map<String, dynamic>.from(jsonDecode(raw) as Map),
        );
    } catch (_) {
      value = const SocialConfig();
      error = '社交配置读取失败，自动互动已关闭。';
    }
    notifyListeners();
  }

  Future<bool> save(SocialConfig next) async {
    var success = false;
    _writes = _writes.then((_) async {
      try {
        if (!await (await SharedPreferences.getInstance()).setString(
          storageKey,
          jsonEncode(next.toJson()),
        )) {
          throw StateError('save failed');
        }
        value = next;
        error = null;
        success = true;
      } catch (_) {
        error = '设置未能保存，请重试。';
      }
      notifyListeners();
    });
    await _writes;
    return success;
  }
}

final socialSettings = SocialSettings();
