import SwiftUI

// MARK: - AI (dev.md §3, design-roadmap.md §7.6)

/// Provider/key/master toggle are global-only concepts — BYOK key
/// management doesn't make sense scoped to one book — so this section is
/// hidden entirely in per-book mode; only `AIFeaturesSection` below applies
/// there.
struct AIProviderSection: View {
    @Bindable var viewModel: ConfigurationViewModel
    @State private var apiKeyText = ""

    var body: some View {
        if !viewModel.isPerBook {
            Section {
                Toggle("Enable AI Features", isOn: aiEnabledBinding)

                Picker("Provider", selection: provider) {
                    Text("None").tag(AIProviderKind?.none)
                    ForEach(AIProviderKind.allCases, id: \.self) { provider in
                        Text(provider.displayName).tag(AIProviderKind?.some(provider))
                    }
                }

                if let selectedProvider = viewModel.aiProvider {
                    SecureField("\(selectedProvider.displayName) API Key", text: $apiKeyText)
                        .textContentType(.password)
                        .onChange(of: apiKeyText) { _, newValue in
                            viewModel.setAPIKey(newValue, for: selectedProvider)
                        }
                        .onAppear { apiKeyText = viewModel.apiKey(for: selectedProvider) }
                        .onChange(of: selectedProvider) { _, newProvider in
                            apiKeyText = viewModel.apiKey(for: newProvider)
                        }
                }
            } header: {
                Text("AI")
            } footer: {
                Text(
                    """
                    Any enabled AI feature sends the relevant book text to your chosen provider's API. \
                    Your key is stored in the Keychain, never in this app's own data.
                    """
                )
            }
        }
    }

    private var aiEnabledBinding: Binding<Bool> {
        Binding(get: { viewModel.aiFeaturesMasterToggle }, set: { viewModel.aiFeaturesMasterToggle = $0 })
    }

    private var provider: Binding<AIProviderKind?> {
        Binding(get: { viewModel.aiProvider }, set: { viewModel.aiProvider = $0 })
    }
}

struct AIFeaturesSection: View {
    @Bindable var viewModel: ConfigurationViewModel

    var body: some View {
        Section {
            ForEach(AIFeatureKey.allCases, id: \.self) { key in
                Toggle(key.displayName, isOn: binding(for: key))
                    .disabled(!viewModel.aiProviderIsUsable || !viewModel.aiFeaturesMasterToggle)
                if viewModel.isPerBook, viewModel.isAIFeatureOverridden(key) {
                    Button("Reset \"\(key.displayName)\" to Default") {
                        viewModel.resetAIFeatureOverride(key)
                    }
                    .font(.caption)
                }
            }
        } header: {
            Text("AI Features")
        } footer: {
            if !viewModel.aiProviderIsUsable {
                Text("Select a provider and enter an API key to enable AI features.")
            } else if viewModel.isPerBook {
                Text("Toggles here override the global default for this book only.")
            }
        }
    }

    private func binding(for key: AIFeatureKey) -> Binding<Bool> {
        Binding(
            get: { viewModel.isAIFeatureEnabled(key) },
            set: { newValue in viewModel.setAIFeatureEnabled(key, newValue) }
        )
    }
}
