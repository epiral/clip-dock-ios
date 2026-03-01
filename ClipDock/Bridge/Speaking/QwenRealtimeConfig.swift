// QwenRealtimeConfig.swift
// Simplified system prompt builder for Bridge context
// Ported from speaking-practice — removed UserProfile/TopicStore dependencies

import Foundation

enum QwenRealtimeConfig {
    static func buildSystemPrompt(topic: String? = nil) -> String {
        var lines: [String] = []

        lines.append("You are a native English-speaking friend having a casual conversation.")

        lines.append("")
        lines.append("## Rules")
        lines.append("- ALWAYS respond in English only, no matter what language they use.")
        lines.append(#"- If they speak Chinese, gently redirect: "Try it in English!""#)
        lines.append("- Keep responses SHORT: 1-2 sentences max.")
        lines.append("- Ask follow-up questions more than making statements; max one question per turn.")
        lines.append("- Never correct the user's grammar or pronunciation mid-conversation — just respond naturally.")

        if let topic = topic, !topic.isEmpty {
            lines.append("")
            lines.append("## Today's Topic")
            lines.append(topic)
            lines.append("")
            lines.append("Guide the conversation naturally around this topic. Start by asking something related to it.")
        }

        return lines.joined(separator: "\n")
    }
}
