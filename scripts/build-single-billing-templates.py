#!/usr/bin/env python3
"""Round-one unsigned single-bill templates. No tests, signing or App builds.
The plist schema is unofficial; importing and property bindings need device checks.
Run only in the authorized build environment/workstation, never install tools.
"""
import argparse
import plistlib
from pathlib import Path
from uuid import uuid5, NAMESPACE_URL

MODES = {"image": "图片 AI", "text": "文字 AI", "expense": "手填支出", "income": "手填收入", "transfer": "手填转账"}

def build(mode, bundle="com.tntlikely.beecount", team="0000000000"):
    def uid(label):
        return str(uuid5(NAMESPACE_URL, "beecount/single-system/v1/" + mode + "/" + label)).upper()
    def action(identifier, label, **params):
        return {"WFWorkflowActionIdentifier": identifier, "WFWorkflowActionParameters": {"UUID": uid(label), **params}}
    def token(value):
        return {"Value": value, "WFSerializationType": "WFTextTokenAttachment"}
    def text(value):
        if isinstance(value, str):
            return {"Value": {"string": value, "attachmentsByRange": {}}, "WFSerializationType": "WFTextTokenString"}
        return {"Value": {"string": "\ufffc", "attachmentsByRange": {"{0, 1}": value}}, "WFSerializationType": "WFTextTokenString"}
    def output(label):
        return {"Type": "ActionOutput", "OutputUUID": uid(label), "OutputName": label}
    def variable(name):
        return token({"Type": "Variable", "VariableName": name})
    def prop(name, title, identifier):
        return {"Type": "Variable", "VariableName": name, "Aggrandizements": [{"Type": "WFPropertyVariableAggrandizement", "PropertyName": title, "PropertyUserInfo": identifier}]}
    def native(name, label, **params):
        return action(bundle + "." + name, label, AppIntentDescriptor={"AppIntentIdentifier": name, "BundleIdentifier": bundle, "Name": "蜜蜂记账", "TeamIdentifier": team, "ActionRequiresAppInstallation": True}, **params)
    def setstep(label):
        return action("is.workflow.actions.setvariable", "set-" + label, WFVariableName="单笔步骤", WFInput=token(output(label)))
    def condition(label, name, title, identifier, value):
        return action("is.workflow.actions.conditional", label, GroupingIdentifier=uid(label + "-group"), WFControlFlowMode=0,
                      WFInput={"Type": "Variable", "Variable": token(prop(name, title, identifier))}, WFCondition=4, WFConditionalActionString=value)
    def otherwise(label):
        return action("is.workflow.actions.conditional", label + "-else", GroupingIdentifier=uid(label + "-group"), WFControlFlowMode=1)
    def end(label):
        return action("is.workflow.actions.conditional", label + "-end", GroupingIdentifier=uid(label + "-group"), WFControlFlowMode=2)
    def stop(label):
        return action("is.workflow.actions.exit", label)
    def resume(label, key, source):
        return [native("ContinueSingleBillingIntent", label, step=variable("单笔步骤"), hasResponse=True, **{key: token(output(source))}), setstep(label)]
    actions = [action("is.workflow.actions.comment", "about", WFCommentActionText=
        "第一轮完整单笔（需要 Build 20 或更新版）。最后点确认提交会真实入账，先用小额测试。"
        "系统请求输入带当前值；取消或中断不保存。没有拆分。模板未签名且尚未导入验证，"
        "若签名更换 Bundle ID，须用实际值重新生成。附图请在保存动作手动连接原图，默认不保存附件。")]
    start = {"source": mode}
    if mode == "image":
        actions.append(action("is.workflow.actions.selectphoto", "photo", WFSelectMultiplePhotos=False))
        start["image"] = token(output("photo"))
    elif mode == "text":
        actions.append(action("is.workflow.actions.ask", "source-text", WFAskActionPrompt="请输入或粘贴记账文字", WFInputType="Text", WFAskActionAllowsMultiline=True))
        start["text"] = token(output("source-text"))
    actions += [native("StartSingleBillingIntent", "start", **start), setstep("start"),
                native("ContinueSingleBillingIntent", "first", step=variable("单笔步骤"), hasResponse=False), setstep("first")]
    group = uid("loop-group")
    actions.append(action("is.workflow.actions.repeat.count", "loop", GroupingIdentifier=group, WFControlFlowMode=0, WFRepeatCount=100))
    actions.append(condition("confirmed", "单笔步骤", "步骤状态", "status", "confirmed"))
    actions += [native("SaveSingleBillingIntent", "save", step=variable("单笔步骤")), stop("saved"), end("confirmed")]
    actions.append(condition("input", "单笔步骤", "步骤状态", "status", "input"))
    actions.append(condition("number", "单笔步骤", "输入类型", "inputType", "number"))
    actions.append(action("is.workflow.actions.ask", "ask-number", WFAskActionPrompt=text(prop("单笔步骤", "输入提示", "prompt")), WFInputType="Number",
                          WFAskActionDefaultAnswer=text(prop("单笔步骤", "当前数字", "currentNumber"))))
    actions += resume("resume-number", "number", "ask-number")
    actions.append(otherwise("number"))
    actions.append(condition("date", "单笔步骤", "输入类型", "inputType", "date"))
    actions.append(action("is.workflow.actions.ask", "ask-date", WFAskActionPrompt=text(prop("单笔步骤", "输入提示", "prompt")), WFInputType="Date",
                          WFAskActionDateGranularity="Date and Time", WFAskActionDefaultAnswerDate=token(prop("单笔步骤", "当前时间", "currentDate"))))
    actions += resume("resume-date", "date", "ask-date")
    actions.append(otherwise("date"))
    actions.append(action("is.workflow.actions.ask", "ask-text", WFAskActionPrompt=text(prop("单笔步骤", "输入提示", "prompt")), WFInputType="Text",
                          WFAskActionDefaultAnswer=text(prop("单笔步骤", "当前内容", "currentText")), WFAskActionAllowsMultiline=True))
    actions += resume("resume-text", "text", "ask-text")
    actions += [end("date"), end("number"), otherwise("input"), stop("cancelled-or-unknown"), end("input")]
    actions += [action("is.workflow.actions.repeat.count", "loop-end", GroupingIdentifier=group, WFControlFlowMode=2),
                action("is.workflow.actions.alert", "limit", WFAlertActionTitle="未入账", WFAlertActionMessage="已达编辑次数上限，未自动保存。请重新运行。"), stop("limit-stop")]
    return {"WFWorkflowClientVersion": "3607.0.5", "WFWorkflowMinimumClientVersion": 900, "WFWorkflowMinimumClientVersionString": "900",
            "WFWorkflowName": "蜜蜂单笔-" + MODES[mode], "WFWorkflowIcon": {"WFWorkflowIconStartColor": 4282601983, "WFWorkflowIconGlyphNumber": 61440},
            "WFWorkflowTypes": [], "WFWorkflowInputContentItemClasses": [], "WFWorkflowOutputContentItemClasses": [],
            "WFWorkflowHasShortcutInputVariables": False, "WFWorkflowActions": actions, "WFWorkflowImportQuestions": []}

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bundle-id", default="com.tntlikely.beecount")
    parser.add_argument("--team-id", default="0000000000")
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    for mode in MODES:
        path = args.output / (mode + ".unsigned.shortcut")
        path.write_bytes(plistlib.dumps(build(mode, args.bundle_id, args.team_id), fmt=plistlib.FMT_XML, sort_keys=False))
        print(path)

if __name__ == "__main__":
    main()
