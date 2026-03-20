import SwiftUI
import WidgetKit

private struct WidgetCamera: Identifiable {
    let id: String
    let label: String
}

private let widgetCameras: [WidgetCamera] = [
    WidgetCamera(id: "fxn_r", label: "FXN R"),
    WidgetCamera(id: "cpm35", label: "CPM35"),
    WidgetCamera(id: "inst_sqc", label: "INST SQC"),
    WidgetCamera(id: "grd_r", label: "GRD R"),
    WidgetCamera(id: "ccd_r", label: "CCD R"),
    WidgetCamera(id: "bw_classic", label: "BW"),
]

private struct DazzWidgetEntry: TimelineEntry {
    let date: Date
}

private struct DazzWidgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> DazzWidgetEntry {
        DazzWidgetEntry(date: Date())
    }

    func getSnapshot(in context: Context, completion: @escaping (DazzWidgetEntry) -> Void) {
        completion(DazzWidgetEntry(date: Date()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<DazzWidgetEntry>) -> Void) {
        let entry = DazzWidgetEntry(date: Date())
        completion(Timeline(entries: [entry], policy: .never))
    }
}

private struct WidgetCard<Content: View>: View {
    let title: String
    let content: Content

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(Color(red: 0.07, green: 0.07, blue: 0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .stroke(Color.white.opacity(0.12), lineWidth: 1)
                )

            VStack(alignment: .leading, spacing: 12) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundColor(.white.opacity(0.78))
                    .tracking(0.8)
                content
            }
            .padding(16)
        }
    }
}

private struct CameraButton: View {
    let camera: WidgetCamera

    private var destination: URL {
        URL(string: "dazzretro://widget/camera?cameraId=\(camera.id)")!
    }

    var body: some View {
        Link(destination: destination) {
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.white.opacity(0.10))
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(Color.white.opacity(0.16), lineWidth: 1)
                    )
                Text(camera.label)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundColor(.white)
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.8)
                    .padding(.horizontal, 6)
            }
        }
        .buttonStyle(.plain)
    }
}

private struct DazzSmallWidgetView: View {
    var entry: DazzWidgetProvider.Entry

    var body: some View {
        WidgetCard(title: "DAZZ") {
            CameraButton(camera: widgetCameras[0])
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct DazzMediumWidgetView: View {
    var entry: DazzWidgetProvider.Entry

    private let columns = [GridItem(.flexible()), GridItem(.flexible())]
    private let cameras = Array(widgetCameras.prefix(4))

    var body: some View {
        WidgetCard(title: "DAZZ CAMERAS") {
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(cameras) { camera in
                    CameraButton(camera: camera)
                        .frame(height: 58)
                }
            }
        }
    }
}

private struct DazzLargeWidgetView: View {
    var entry: DazzWidgetProvider.Entry

    private let columns = [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())]

    var body: some View {
        WidgetCard(title: "DAZZ CAMERA GRID") {
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(widgetCameras) { camera in
                    CameraButton(camera: camera)
                        .frame(height: 58)
                }
            }
        }
    }
}

struct DazzCameraSmallWidget: Widget {
    let kind = "DazzCameraSmallWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: DazzWidgetProvider()) { entry in
            DazzSmallWidgetView(entry: entry)
        }
        .configurationDisplayName("DAZZ Quick Camera")
        .description("Launch straight into FXN R from your Home Screen.")
        .supportedFamilies([.systemSmall])
    }
}

struct DazzCameraMediumWidget: Widget {
    let kind = "DazzCameraMediumWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: DazzWidgetProvider()) { entry in
            DazzMediumWidgetView(entry: entry)
        }
        .configurationDisplayName("DAZZ Camera Grid")
        .description("Open four favorite DAZZ cameras in one tap.")
        .supportedFamilies([.systemMedium])
    }
}

struct DazzCameraLargeWidget: Widget {
    let kind = "DazzCameraLargeWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: DazzWidgetProvider()) { entry in
            DazzLargeWidgetView(entry: entry)
        }
        .configurationDisplayName("DAZZ Full Grid")
        .description("A two-row launcher for the full DAZZ widget camera lineup.")
        .supportedFamilies([.systemLarge])
    }
}

@main
struct DazzCameraWidgetsBundle: WidgetBundle {
    var body: some Widget {
        DazzCameraSmallWidget()
        DazzCameraMediumWidget()
        DazzCameraLargeWidget()
    }
}
