Map<String, dynamic> _object(
  Map<String, dynamic> fields, {
  List<String> required = const [],
  bool open = false,
}) => {
  'type': 'object',
  'properties': fields,
  'required': required,
  'additionalProperties': open,
};

final phoneFlowSelector = _object({
  for (final key in [
    'text',
    'textContains',
    'description',
    'descriptionContains',
    'viewId',
    'className',
  ])
    key: {'type': 'string'},
  for (final key in [
    'clickable',
    'editable',
    'scrollable',
    'checked',
    'selected',
    'enabled',
  ])
    key: {'type': 'boolean'},
  'within': _object({}, open: true),
  'source': {
    'type': 'string',
    'enum': ['accessibility', 'ocr'],
  },
  'region': {
    'type': 'array',
    'minItems': 4,
    'maxItems': 4,
    'items': {'type': 'number', 'minimum': 0, 'maximum': 1},
    'description': '目标所在屏幕区域 [左,上,右,下]，使用0–1比例消除同名歧义；每次重新识别实际位置。',
  },
});

final phoneFlowCondition = _object(
  {
    'kind': {
      'type': 'string',
      'enum': [
        'exists',
        'absent',
        'checked',
        'visual_checked',
        'selected',
        'text',
        'changed',
        'all',
        'any',
      ],
    },
    'selector': phoneFlowSelector,
    'text': {'type': 'string'},
    'checked': {'type': 'boolean'},
    'selected': {'type': 'boolean'},
    'conditions': {'type': 'array', 'items': _object({}, open: true)},
  },
  required: ['kind'],
);

final phoneFlowParameters = _object(
  {
    'package': {'type': 'string'},
    'recognitionMode': {
      'type': 'string',
      'enum': ['auto', 'visual', 'controls'],
    },
    'steps': {
      'type': 'array',
      'items': _object(
        {
          'id': {'type': 'string'},
          'action': {
            'type': 'string',
            'enum': [
              'tap',
              'set_checked',
              'input',
              'scroll',
              'swipe',
              'back',
              'wait',
            ],
          },
          'selector': phoneFlowSelector,
          'text': {'type': 'string'},
          'checked': {'type': 'boolean'},
          'direction': {'type': 'string'},
          'guard': phoneFlowCondition,
          'when': phoneFlowCondition,
          'expect': phoneFlowCondition,
          'timeoutMs': {
            'type': 'integer',
            'minimum': 0,
            'description': '本步骤等待期限，0或省略不额外限时；可随时停止。',
          },
          'stableMs': {
            'type': 'integer',
            'minimum': 0,
            'description': '核对条件连续成立的时间，默认100毫秒。',
          },
        },
        required: ['id', 'action'],
      ),
    },
  },
  required: ['package', 'steps'],
);

final phoneFlowReferenceParameters = _object(
  {
    'originalRequestId': {'type': 'string'},
  },
  required: ['originalRequestId'],
);

/// Conditional requirements are also checked before crossing the native bridge.
/// Native validation remains authoritative for selectors and observed evidence.
void validatePhoneFlowSemantics(Map<String, dynamic> arguments) {
  for (final step in (arguments['steps'] as List).cast<Map>()) {
    if (step['action'] == 'set_checked') {
      if (step['checked'] is! bool || step['selector'] is! Map) {
        throw const FormatException('set_checked 需要 selector 与 checked 布尔值。');
      }
    } else if (step['expect'] is! Map) {
      throw const FormatException('手机流程步骤缺少明确的 expect 核对条件。');
    }
  }
}

const phoneFlowInstructions =
    '''手机连续操作优先使用 ui.flow，一次提供一段已明确的本地步骤，执行期间不逐步请求模型。先用 ui.observe 识别真实文字和控件结构；流程以 package 限定软件，不接受旧 observationId/elementId 或屏幕坐标。
steps 的 id 唯一，action 为 tap/set_checked/input/scroll/swipe/back/wait。用 selector 按实际可见 text、description、viewId、className 或可编辑等状态定位；textContains/descriptionContains 为包含匹配，within 可限定祖先。动作目标必须唯一。input 另传 text；scroll direction 为 forward/backward，swipe 为 up/down/left/right。
选择单选、多选或开关优先用 set_checked，另传 checked:true/false；宿主自动读取真实状态、必要时操作一次并核实，无需模型编写选中 expect。已处于目标状态时保持原状态。可附加 expect 与宿主的选中证据共同核验。存在下一步依赖时，只有前步真实核验成功才执行；流程最后直接附最新观察，可用于下一次判断。
其他步骤必须给 expect：checked/visual_checked/selected 核对真实状态；text/exists/absent 核对动作前后明确的目标变化；all/any 组合必须包含有效结果证据。题号、题干或选项文字在点击前已经存在，只能作为 guard，不能作为已选中证据或据此跳过动作。changed 只用于明确目标原生控件的相关变化，不接受整个页面或无关区域变化作为业务结果。when 为条件分支，不成立会跳过该步。
recognitionMode 可选 auto（控件不足时本地OCR）、visual（视觉优先）、controls（仅控件），省略沿用用户设置。ui.observe 同样支持该参数；只有文字模型也可使用本地返回的文字与位置。selector.source 可限定 accessibility/ocr；region 为 [左,上,右,下] 的0–1屏幕比例，用于同名文字消歧。视觉动作在本地重新识别并核对目标区域后定位，执行期间不逐步请求模型。OCR文字本身不推断选中状态；带 visualChecked 与当前观察绑定的标记识别证据时才可核验视觉选中，未知样式会明确报告缺少状态证据。不要把文字仍存在或点击已派发当作选中。
timeoutMs 为本步等待期限，0或省略不额外限时，stableMs 默认100。流程自动重新定位、等待和核验；结果提供每步耗时、执行状态和当前观察。unknown/cancelled 不代表动作未执行，先 ui.flow.read 查询原 originalRequestId，明确继续原流程时用 ui.flow.resume；恢复只核对未知动作，绝不重新点击。ui.screenshot 仍可用于需要模型视觉理解的图标或图像，不能虚构视觉或业务成功。''';
