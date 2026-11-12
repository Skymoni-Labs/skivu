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
            'enum': ['tap', 'input', 'scroll', 'swipe', 'back', 'wait'],
          },
          'selector': phoneFlowSelector,
          'text': {'type': 'string'},
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
        required: ['id', 'action', 'expect'],
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

const phoneFlowInstructions =
    '''手机连续操作优先使用 ui.flow，一次提供一段已明确的本地步骤，执行期间不逐步请求模型。先用 ui.observe 识别真实文字和控件结构；流程以 package 限定软件，不接受旧 observationId/elementId 或屏幕坐标。
steps 的 id 唯一，action 为 tap/input/scroll/swipe/back/wait。tap/input/scroll/swipe 用 selector 按 text、description、viewId、className 或可编辑等状态定位；textContains/descriptionContains 为包含匹配，within 可限定祖先。动作目标必须唯一。input 另传 text；scroll direction 为 forward/backward，swipe 为 up/down/left/right。
每步必须给 expect：{kind:"checked",selector:{text:"选项原文"},checked:true}；text/selected 相应传 text/selected；exists/absent 核对控件出现/消失；changed 核对 selector 所在区域内容变化，无 selector 核对整个页面；all/any 用 conditions 组合。已满足 expect 时不重复动作。题目等重复布局给 guard（如题干文字 exists）检查动作前页面，选择后的 expect 用 all 同时核对题干和选中状态；不要用计时器或无关区域变化证明翻题。when 为条件分支，不成立会跳过该步。
recognitionMode 可选 auto（控件不足时本地OCR）、visual（视觉优先）、controls（仅控件），省略沿用用户设置。ui.observe 同样支持该参数；只有文字模型也可使用OCR返回的文字与位置，无需接收图片。selector.source 可限定 accessibility/ocr；region 为 [左,上,右,下] 的0–1屏幕比例，用于同名文字消歧。视觉动作在本地重新识别并核对目标区域后定位，执行期间不逐步请求模型。OCR行不推断 clickable、editable、checked 或 selected；用 exists/absent/text 核对实际目标文字，changed 仅用于可访问控件，不能用OCR识别波动或任意图像变化证明业务完成；勾选状态需要实际控件证据；不要把文字仍存在或点击已派发当作选中。
timeoutMs 为本步等待期限，0或省略不额外限时，stableMs 默认100。流程自动重新定位、等待和核验；结果提供每步耗时、执行状态和当前观察。unknown/cancelled 不代表动作未执行，先 ui.flow.read 查询原 originalRequestId，明确继续原流程时用 ui.flow.resume；恢复只核对未知动作，绝不重新点击。ui.screenshot 仍可用于需要模型视觉理解的图标或图像，不能虚构视觉或业务成功。''';
