import 'package:ski/state.dart';

void seedPreviewConversation() {
  demo.conversations
    ..clear()
    ..add(
      Conversation('布局测试', [
        Message(true, '今天事情有点多，想先聊一会儿。'),
        Message(false, '我在。先不用急着把所有事情处理好，慢慢说就好。'),
        Message(
          false,
          '也可以先把脑海里的想法放到一边。\n\n一起把今天最重要的事情写下来，再安排一个能完成的小步骤。\n\n这是一段用于布局测试的文字。',
        ),
        Message(true, '好呀，也想安排一次小旅行。'),
        Message(false, '可以先确定时间、地点和预算，然后整理出轻松的行程。\n\n不用急着决定所有细节，我们可以慢慢讨论。'),
      ]),
    );
  demo.conversation = 0;
}
