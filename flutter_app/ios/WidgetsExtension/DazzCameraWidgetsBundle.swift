import SwiftUI
import WidgetKit

private struct WidgetCamera: Identifiable {
    let id: String
    let label: String
    let symbolName: String
    let accent: Color
    let accentSecondary: Color
}

private let widgetCameras: [WidgetCamera] = [
    WidgetCamera(
        id: "fxn_r",
        label: "FXN R",
        symbolName: "camera.aperture",
        accent: Color(red: 0.97, green: 0.27, blue: 0.24),
        accentSecondary: Color(red: 1.0, green: 0.73, blue: 0.28)
    ),
    WidgetCamera(
        id: "cpm35",
        label: "CPM35",
        symbolName: "camera.macro",
        accent: Color(red: 0.19, green: 0.79, blue: 0.65),
        accentSecondary: Color(red: 0.95, green: 0.95, blue: 0.58)
    ),
    WidgetCamera(
        id: "inst_sqc",
        label: "INST SQC",
        symbolName: "camera.viewfinder",
        accent: Color(red: 0.38, green: 0.64, blue: 1.0),
        accentSecondary: Color(red: 0.88, green: 0.58, blue: 0.96)
    ),
    WidgetCamera(
        id: "grd_r",
        label: "GRD R",
        symbolName: "camera",
        accent: Color(red: 0.83, green: 0.83, blue: 0.83),
        accentSecondary: Color(red: 0.58, green: 0.58, blue: 0.60)
    ),
    WidgetCamera(
        id: "ccd_r",
        label: "CCD R",
        symbolName: "sparkles.tv",
        accent: Color(red: 0.30, green: 0.80, blue: 1.0),
        accentSecondary: Color(red: 0.79, green: 0.93, blue: 1.0)
    ),
    WidgetCamera(
        id: "bw_classic",
        label: "BW",
        symbolName: "circle.lefthalf.filled",
        accent: Color(red: 0.94, green: 0.94, blue: 0.94),
        accentSecondary: Color(red: 0.51, green: 0.51, blue: 0.53)
    ),
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
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.12, green: 0.12, blue: 0.14),
                            Color(red: 0.05, green: 0.05, blue: 0.06)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .stroke(Color.white.opacity(0.10), lineWidth: 1)
                )
                .overlay(alignment: .topTrailing) {
                    Circle()
                        .fill(Color.white.opacity(0.08))
                        .frame(width: 82, height: 82)
                        .blur(radius: 2)
                        .offset(x: 22, y: -22)
                }

            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [
                                        Color(red: 0.22, green: 0.16, blue: 0.10),
                                        Color(red: 0.44, green: 0.30, blue: 0.18)
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .frame(width: 34, height: 34)
                        Image(systemName: "camera.aperture")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundColor(.white)
                    }
                    Text(title)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundColor(.white.opacity(0.92))
                        .tracking(0.4)
                    Spacer(minLength: 0)
                }
                content
            }
            .padding(16)
        }
    }
}

private struct CameraGlyph: View {
    let camera: WidgetCamera

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            camera.accent.opacity(0.95),
                            camera.accentSecondary.opacity(0.92)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.white.opacity(0.22), lineWidth: 1)

            VStack(spacing: 6) {
                ZStack {
                    Circle()
                        .fill(Color.black.opacity(0.16))
                        .frame(width: 26, height: 26)
                    Image(systemName: camera.symbolName)
                        .font(.system(size: 15, weight: .bold))
                        .foregroundColor(.white)
                }
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(Color.white.opacity(0.88))
                    .frame(width: 28, height: 4)
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(Color.black.opacity(0.22))
                    .frame(width: 18, height: 3)
            }
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
            VStack(spacing: 8) {
                CameraGlyph(camera: camera)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                Text(camera.label)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundColor(.white.opacity(0.92))
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
            HStack(spacing: 12) {
                CameraGlyph(camera: widgetCameras[0])
                    .frame(width: 84, height: 84)
                VStack(alignment: .leading, spacing: 6) {
                    Text(widgetCameras[0].label)
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                    Text("Quick Launch")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundColor(.white.opacity(0.66))
                    Spacer(minLength: 0)
                    Link(destination: URL(string: "dazzretro://widget/camera?cameraId=\(widgetCameras[0].id)")!) {
                        Text("Open")
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                            .foregroundColor(.black)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(Color.white)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
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
                        .frame(height: 92)
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
                        .frame(height: 92)
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
