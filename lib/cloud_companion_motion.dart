import 'dart:ui';

enum CloudPetSegment { start, loop, end, hold }

/// Visual states follow task receipts; they never dispatch tools or replay work.
enum CloudActivity {
  idle,
  thinking,
  coding,
  phone,
  permission,
  checking,
  resultReady,
  complete,
  stopping,
  paused,
  failed;

  String get label => switch (this) {
    idle => '小云在这里',
    thinking => '正在思考',
    coding => '正在执行代码',
    phone => '正在操作手机',
    permission => '等待你的授权',
    checking => '结果需要核对',
    resultReady => '结果已就绪',
    complete => '已核实完成',
    stopping => '正在停止，等待回执',
    paused => '已暂停',
    failed => '遇到问题了',
  };
  bool get continuous =>
      this == idle ||
      this == thinking ||
      this == coding ||
      this == phone ||
      this == checking;
}

CloudActivity cloudActivityForTask(String phase, {String? tool}) =>
    switch (phase) {
      'thinking' => CloudActivity.thinking,
      'executing' =>
        tool == 'shell.execute'
            ? CloudActivity.coding
            : tool != null &&
                  (tool.startsWith('ui.') || tool.startsWith('android.'))
            ? CloudActivity.phone
            : CloudActivity.checking,
      'permission' => CloudActivity.permission,
      'confirmation' => CloudActivity.paused,
      'awaiting_verification' => CloudActivity.checking,
      'unknown' => CloudActivity.checking,
      // A final model answer is not proof of a successful device operation.
      'done' => CloudActivity.resultReady,
      'stopping' => CloudActivity.stopping,
      'stopped' => CloudActivity.paused,
      'failed' => CloudActivity.failed,
      _ => CloudActivity.idle,
    };

/// Keeps a task's workspace while thinking or waiting. Actual joint weights
/// belong to the approved artwork's connected mesh, never to replacement limbs.
class CloudPose {
  const CloudPose({this.computer = 0, this.phone = 0, this.permission = 0});
  final double computer, phone, permission;
  static CloudPose forActivity(CloudActivity activity, int workspace) =>
      CloudPose(
        computer: workspace == 1 ? 1 : 0,
        phone: workspace == 2 ? 1 : 0,
        permission: activity == CloudActivity.permission ? 1 : 0,
      );
  static CloudPose lerp(CloudPose a, CloudPose b, double t) => CloudPose(
    computer: lerpDouble(a.computer, b.computer, t)!,
    phone: lerpDouble(a.phone, b.phone, t)!,
    permission: lerpDouble(a.permission, b.permission, t)!,
  );
}

/// Captures an outgoing motion phase so an interrupted fade does not restart it.
class CloudVisualLayer {
  const CloudVisualLayer({
    required this.activity,
    required this.pose,
    required this.seconds,
    required this.opacity,
    required this.greeting,
    this.petSegment,
    this.petAtlasAsset,
    this.smoothFrame = false,
    this.freezeMotion = false,
  });
  final CloudActivity activity;
  final CloudPose pose;
  final double seconds, opacity;
  final bool greeting;
  final CloudPetSegment? petSegment;
  final String? petAtlasAsset;
  final bool smoothFrame;
  final bool freezeMotion;
  CloudVisualLayer withOpacity(double value) => CloudVisualLayer(
    activity: activity,
    pose: pose,
    seconds: seconds,
    opacity: value,
    greeting: greeting,
    petSegment: petSegment,
    petAtlasAsset: petAtlasAsset,
    smoothFrame: smoothFrame,
    freezeMotion: freezeMotion,
  );
}
