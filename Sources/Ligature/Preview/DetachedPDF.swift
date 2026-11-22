import SwiftUI

/// The project's PDF in a separate window. While it's open the project window shows only the editor; closing
/// it brings the PDF back.
struct DetachedPDFWindow: View {
    let root: URL?
    @State private var model: ProjectModel?

    var body: some View {
        Group {
            if let model {
                PDFPane(model: model)
                    .background(AmbientBackdrop(pulse: model.pdfVersion))
                    .navigationTitle("\(model.name) — PDF")
                    .toolbar {
                        ToolbarItem(placement: .primaryAction) {
                            Button { model.compile(manual: true) } label: { Label("Compile", systemImage: "play.fill") }
                                .help("Compile (⌘R)")
                        }
                        ToolbarItem(placement: .primaryAction) {
                            Button { attachBack(model) } label: { Label("Back to Project Window", systemImage: "rectangle.righthalf.inset.filled") }
                                .help("Show the PDF in the project window again")
                        }
                    }
                    .onAppear {
                        model.pdfDetached = true
                        withAnimation(.panel) { model.layout = .editor }
                    }
                    .onDisappear {
                        model.pdfDetached = false
                        if model.layout == .editor { withAnimation(.panel) { model.layout = .split } }
                    }
            } else {
                EmptyState(symbol: "doc.richtext", title: "Project not open", message: "Open the project to see its PDF here.")
            }
        }
        .frame(minWidth: 420, minHeight: 500)
        .preferredColorScheme(Preferences.shared.themeID == "auto" ? nil : (theme.isDark ? .dark : .light))
        .onAppear { model = ProjectModel.openModels.allObjects.first { $0.root.standardizedFileURL == root?.standardizedFileURL } }
    }

    private func attachBack(_ model: ProjectModel) {
        NSApp.keyWindow?.close()
    }
}
