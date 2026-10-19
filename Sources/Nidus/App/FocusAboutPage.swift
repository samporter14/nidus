//
//  FocusAboutPage.swift
//  Nidus
//
//  Settings, About: the icon, the name and version, and what Nidus does with
//  your data (nothing: it keeps its history on this Mac, and that is the one
//  switch). No links: Nidus never connects to the internet, so it has no
//  page to send you to.
//

import AppKit
import SwiftUI

struct FocusAboutPage: View {
    @ObservedObject var model: NidusModel
    var version: String? = Self.bundleVersion

    static let tagline = "Blocks what pulls you away, for as long as you say. Nothing leaves this Mac."
    static let privacy = "Nidus collects nothing and never connects to the internet. What it keeps stays on this Mac."
    static let credits = "Made by Sam. MIT licensed."

    /// The icon and credits are on the page itself, centred as an About box
    /// has them, and the form between holds the one setting. A form would
    /// put them in cards.
    var body: some View {
        VStack(spacing: 0) {
            identity
            NidusSettingsPane {
                NidusSettingsSection {
                    settingsSectionHeader("Privacy", detail: Self.privacy)
                } content: {
                    NidusSettingsCard {
                        NidusToggleRow(title: "Record session history",
                                         subtitle: "Used only for your stats and recent goals, and kept only on this Mac. When off, neither is kept.",
                                         isOn: model.binding(\.recordsHistory))
                    }
                }
            }
            credit
        }
    }

    private var identity: some View {
        VStack(spacing: 4) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
                .accessibilityHidden(true)
            Text("Nidus")
                .font(.title.weight(.semibold))
            if let line = Self.versionLine(version) {
                Text(line)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Text(Self.tagline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.top, 4)
        }
        .padding(.horizontal, NidusSpacing.lg)
        .padding(.top, NidusSpacing.lg + NidusSpacing.sm)
        .padding(.bottom, NidusSpacing.xs)
        .accessibilityElement(children: .combine)
    }

    private var credit: some View {
        Text(Self.credits)
            .font(.callout)
            .foregroundStyle(.tertiary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, NidusSpacing.lg)
            .padding(.bottom, NidusSpacing.lg)
            .frame(maxWidth: .infinity)
    }

    /// The version in Info.plist; an app run from the build folder has none.
    static var bundleVersion: String? {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    }

    /// "Version 0.1.3", or nothing when there is no version to show, so the
    /// page never carries a bare word with a blank after it.
    static func versionLine(_ version: String?) -> String? {
        guard let version = version?.trimmingCharacters(in: .whitespacesAndNewlines), !version.isEmpty else { return nil }
        return "Version \(version)"
    }
}
