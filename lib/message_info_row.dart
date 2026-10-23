import 'package:flutter/material.dart';
import 'appearance.dart';
import 'state.dart';

/// Reply metadata shares the reply column's width. Names give up space first;
/// the numeric readout stays together at the trailing edge.
class MessageInfoRow extends StatelessWidget {
  const MessageInfoRow({super.key, required this.message, this.preferences});
  final Message message;
  final AppearancePreferences? preferences;

  @override
  Widget build(BuildContext context) {
    final model = preferences ?? appearance;
    final names = [
      if (model.flag('showModel')) message.modelName ?? '模型 —',
      if (model.flag('showProvider')) message.provider ?? '供应商 —',
    ];
    final metrics = <({String text, String detail})>[
      if (model.flag('showTokens'))
        (
          text: '${_tokens(message.tokens)} tok',
          detail: 'Token ${message.tokens ?? '—'}',
        ),
      if (model.flag('showElapsed'))
        (
          text: message.elapsedMs == null
              ? '耗时 —'
              : '${(message.elapsedMs! / 1000).toStringAsFixed(2)}s',
          detail:
              '响应耗时 ${message.elapsedMs == null ? '—' : '${message.elapsedMs} ms'}',
        ),
      if (model.flag('showTime'))
        (
          text:
              '${message.created.hour.toString().padLeft(2, '0')}:${message.created.minute.toString().padLeft(2, '0')}',
          detail: '消息时间 ${message.created.toLocal()}',
        ),
    ];
    if (names.isEmpty && metrics.isEmpty) return const SizedBox.shrink();
    final color = model.textColorEnabled('interfaceText')
        ? model.textColor('interfaceText')
        : const Color(0xff39434f);
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Semantics(
        label: [...names, ...metrics.map((item) => item.detail)].join('，'),
        excludeSemantics: true,
        child: DefaultTextStyle.merge(
          style: TextStyle(fontSize: 10, height: 1.5, color: color),
          child: LayoutBuilder(
            builder: (context, bounds) => Row(
              children: [
                if (names.isNotEmpty)
                  Expanded(
                    child: Row(
                      children: [
                        for (var i = 0; i < names.length; i++) ...[
                          if (i > 0) const SizedBox(width: 6),
                          Expanded(
                            flex: i == 0 ? 3 : 2,
                            child: Tooltip(
                              message: names[i],
                              child: Text(
                                names[i],
                                key: ValueKey('message-info-name-$i'),
                                maxLines: 1,
                                softWrap: false,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                if (names.isNotEmpty && metrics.isNotEmpty)
                  const SizedBox(width: 8),
                if (metrics.isNotEmpty)
                  Flexible(
                    flex: 0,
                    child: ConstrainedBox(
                      constraints: BoxConstraints(
                        maxWidth: names.isEmpty
                            ? bounds.maxWidth
                            : (bounds.maxWidth - 8) * .7,
                      ),
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.centerRight,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            for (var i = 0; i < metrics.length; i++) ...[
                              if (i > 0) const SizedBox(width: 6),
                              Tooltip(
                                message: metrics[i].detail,
                                child: Text(
                                  metrics[i].text,
                                  key: ValueKey('message-info-metric-$i'),
                                  maxLines: 1,
                                  softWrap: false,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  static String _tokens(int? value) {
    if (value == null || value < 0) return '—';
    if (value >= 1000000) return '${(value / 1000000).toStringAsFixed(1)}M';
    if (value >= 1000) return '${(value / 1000).toStringAsFixed(1)}k';
    return '$value';
  }
}
