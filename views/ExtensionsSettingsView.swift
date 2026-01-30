import SwiftUI

struct ExtensionsSettingsView: View {
    @Binding var selectedTab: ExtensionsSettingsTab
    @ObservedObject var preferences: SessionPreferencesStore
    var openMCPMateDownload: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Group {
                if #available(macOS 15.0, *) {
                    TabView(selection: $selectedTab) {
                        Tab("Commands", systemImage: "command", value: ExtensionsSettingsTab.commands) {
                            SettingsTabContent { CommandsSettingsView(preferences: preferences) }
                        }
                        Tab("Hooks", systemImage: "link", value: ExtensionsSettingsTab.hooks) {
                            SettingsTabContent { HooksSettingsView(preferences: preferences) }
                        }
                        Tab("MCP Servers", systemImage: "server.rack", value: ExtensionsSettingsTab.mcp) {
                            SettingsTabContent {
                                MCPServersSettingsPane(
                                    preferences: preferences,
                                    openMCPMateDownload: openMCPMateDownload,
                                    showHeader: false
                                )
                            }
                        }
                        Tab("Skills", systemImage: "sparkles", value: ExtensionsSettingsTab.skills) {
                            SettingsTabContent { SkillsSettingsView(preferences: preferences) }
                        }
                    }
                } else {
                    TabView(selection: $selectedTab) {
                        SettingsTabContent { CommandsSettingsView(preferences: preferences) }
                            .tabItem { Label("Commands", systemImage: "command") }
                            .tag(ExtensionsSettingsTab.commands)

                        SettingsTabContent { HooksSettingsView(preferences: preferences) }
                            .tabItem { Label("Hooks", systemImage: "link") }
                            .tag(ExtensionsSettingsTab.hooks)

                        SettingsTabContent {
                            MCPServersSettingsPane(
                                preferences: preferences,
                                openMCPMateDownload: openMCPMateDownload,
                                showHeader: false
                            )
                        }
                        .tabItem { Label("MCP Servers", systemImage: "server.rack") }
                        .tag(ExtensionsSettingsTab.mcp)

                        SettingsTabContent { SkillsSettingsView(preferences: preferences) }
                            .tabItem { Label("Skills", systemImage: "sparkles") }
                            .tag(ExtensionsSettingsTab.skills)
                    }
                }
            }
            .padding(.bottom, 16)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Extensions Settings")
                .font(.title2)
                .fontWeight(.bold)
            Text("Manage MCP servers, Skills, and Commands across AI CLI providers.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }
}
