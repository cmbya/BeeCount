#!/usr/bin/env python3
"""Build unsigned BeeCount Ask-for-Input templates (stdlib only).
Run only on an authorized workstation. Import requires macOS `shortcuts sign`.
The plist action schema is not a public Apple API; device import must be verified.
"""
import argparse
import plistlib
from pathlib import Path
from uuid import uuid5, NAMESPACE_URL

MODES = {
    'image': ('图片记账', 'ImageConfirmBillingIntent'),
    'text': ('文字记账', 'TextBillingTemplateStartIntent'),
    'expense': ('自定义支出账单', 'CustomExpenseBillingIntent'),
    'income': ('自定义收入账单', 'CustomIncomeBillingIntent'),
    'transfer': ('自定义转账账单', 'CustomTransferBillingIntent'),
}

def build(mode, bundle='com.tntlikely.beecount', team='0000000000'):
    title, intent = MODES[mode]
    def uid(label):
        return str(uuid5(NAMESPACE_URL, 'beecount/ask-input/v1/' + mode + '/' + label)).upper()
    def action(identifier, label, **params):
        return {'WFWorkflowActionIdentifier': identifier,
                'WFWorkflowActionParameters': {'UUID': uid(label), **params}}
    def token(value):
        return {'Value': value, 'WFSerializationType': 'WFTextTokenAttachment'}
    def text(value):
        if isinstance(value, str):
            return {'Value': {'string': value, 'attachmentsByRange': {}}, 'WFSerializationType': 'WFTextTokenString'}
        return {'Value': {'string': '\ufffc', 'attachmentsByRange': {'{0, 1}': value}}, 'WFSerializationType': 'WFTextTokenString'}
    def output(label):
        return {'Type': 'ActionOutput', 'OutputUUID': uid(label), 'OutputName': label}
    def variable(name):
        return token({'Type': 'Variable', 'VariableName': name})
    def native(name, label, **params):
        return action(bundle + '.' + name, label, AppIntentDescriptor={
            'AppIntentIdentifier': name, 'BundleIdentifier': bundle,
            'Name': '蜜蜂记账', 'TeamIdentifier': team}, **params)
    def setvar(name, source):
        return action('is.workflow.actions.setvariable', 'set-' + name + '-' + str(len(actions)), WFVariableName=name, WFInput=token(output(source)))
    def getkey(source, key, label):
        return [action('is.workflow.actions.getvalueforkey', label + '-raw', WFInput=source,
                       WFDictionaryKey=key, WFGetDictionaryValueType='Value'),
                action('is.workflow.actions.gettext', label, WFTextActionText=text(output(label + '-raw')))]
    def condition(label, source, value):
        return action('is.workflow.actions.conditional', label, GroupingIdentifier=uid(label + '-group'),
                      WFControlFlowMode=0, WFInput={'Type': 'Variable', 'Variable': output(source)},
                      WFCondition=4, WFConditionalActionString=value)
    def otherwise(label):
        return action('is.workflow.actions.conditional', label + '-else', GroupingIdentifier=uid(label + '-group'), WFControlFlowMode=1)
    def end(label):
        return action('is.workflow.actions.conditional', label + '-end', GroupingIdentifier=uid(label + '-group'), WFControlFlowMode=2)
    def stop(label):
        return action('is.workflow.actions.exit', label)

    actions = [action('is.workflow.actions.comment', 'about', WFCommentActionText=
        'BeeCount 系统询问输入模板（未签名、待真机验证）。备注和金额点击后预填编辑，取消输入结束且不入账。'
        '必须安装支持模板模式的新版 App。首动作预设账本/账户/金额可自行配置。'
        '附带图片请在最后保存动作连接截图变量，留空不保存附件。')]
    # Ordinary text billing always reviews; draft-only transport has its own action.
    params = {} if mode == 'text' else {'templateMode': True}
    if mode == 'image':
        params['image'] = token({'Type': 'ExtensionInput'})
    elif mode == 'text':
        params['text'] = text({'Type': 'ExtensionInput'})
    actions.append(native(intent, 'start', **params))
    actions.append(setvar('账单步骤', 'start'))
    actions.append(native('ContinueBillingStepIntent', 'first-edit', state=variable('账单步骤'), hasResponse=False))
    actions.append(setvar('账单步骤', 'first-edit'))
    group = uid('loop-group')
    actions.append(action('is.workflow.actions.repeat.count', 'loop', GroupingIdentifier=group, WFControlFlowMode=0, WFRepeatCount=1000))
    actions.append(action('is.workflow.actions.detect.dictionary', 'envelope', WFInput=variable('账单步骤')))
    actions += getkey(token(output('envelope')), 'status', 'status')
    actions.append(condition('confirmed', 'status', 'confirmed'))
    actions.append(native('SaveBillingStepIntent', 'save', state=variable('账单步骤')))
    actions.append(stop('done'))
    actions.append(end('confirmed'))
    actions.append(condition('input', 'status', 'input'))
    actions.append(action('is.workflow.actions.getvalueforkey', 'input-spec', WFInput=token(output('envelope')), WFDictionaryKey='input', WFGetDictionaryValueType='Value'))
    actions += getkey(token(output('input-spec')), 'prompt', 'prompt')
    actions += getkey(token(output('input-spec')), 'currentValue', 'current')
    actions += getkey(token(output('input-spec')), 'inputType', 'input-type')
    # Explicitly clear the prior answer before a potentially empty note response.
    actions.append(action('is.workflow.actions.gettext', 'empty-answer', WFTextActionText=''))
    actions.append(setvar('编辑结果', 'empty-answer'))
    actions.append(condition('number', 'input-type', 'number'))
    actions.append(action('is.workflow.actions.ask', 'ask-number', WFAskActionPrompt=text(output('prompt')),
                          WFInputType='Number', WFAskActionDefaultAnswer=text(output('current'))))
    actions.append(setvar('编辑结果', 'ask-number'))
    actions.append(otherwise('number'))
    actions.append(action('is.workflow.actions.ask', 'ask-text', WFAskActionPrompt=text(output('prompt')),
                          WFInputType='Text', WFAskActionDefaultAnswer=text(output('current')), WFAskActionAllowsMultiline=True))
    actions.append(setvar('编辑结果', 'ask-text'))
    actions.append(end('number'))
    actions.append(native('ContinueBillingStepIntent', 'resume', state=variable('账单步骤'),
                          response=variable('编辑结果'), hasResponse=True))
    actions.append(setvar('账单步骤', 'resume'))
    actions.append(otherwise('input'))
    # cancelled/unknown statuses must not fall through to a save.
    actions.append(stop('cancelled-or-invalid'))
    actions.append(end('input'))
    actions.append(action('is.workflow.actions.repeat.count', 'loop-end', GroupingIdentifier=group, WFControlFlowMode=2))
    actions.append(action('is.workflow.actions.alert', 'limit', WFAlertActionTitle='未入账',
                          WFAlertActionMessage='编辑次数达到上限，请重新运行。未自动保存草稿。'))
    actions.append(stop('limit-stop'))
    return {'WFWorkflowClientVersion': '3036.0.4', 'WFWorkflowMinimumClientVersion': 900,
            'WFWorkflowMinimumClientVersionString': '900',
            'WFWorkflowName': '蜜蜂-' + title + '-系统输入',
            'WFWorkflowIcon': {'WFWorkflowIconStartColor': 4282601983, 'WFWorkflowIconGlyphNumber': 61440},
            'WFWorkflowTypes': ['NCWidget', 'WatchKit', 'ActionExtension'],
            'WFWorkflowInputContentItemClasses': ['WFImageContentItem'] if mode == 'image' else ['WFStringContentItem'],
            'WFWorkflowOutputContentItemClasses': [], 'WFWorkflowHasShortcutInputVariables': mode in ('image', 'text'),
            'WFWorkflowActions': actions, 'WFWorkflowImportQuestions': []}

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--bundle-id', default='com.tntlikely.beecount', help='Must match the installed/signed App')
    parser.add_argument('--team-id', default='0000000000')
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    for mode in MODES:
        target = args.output / (mode + '.unsigned.shortcut')
        target.write_bytes(plistlib.dumps(build(mode, args.bundle_id, args.team_id), fmt=plistlib.FMT_XML, sort_keys=False))
        print(target)

if __name__ == '__main__':
    main()
