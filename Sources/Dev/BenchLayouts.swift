#if TIDEWALL_DEV
import Cocoa

/// Desks to test themes against (--layout NAME): Stage Manager strips, widgets, tiling, crowding, screen edges.
/// Each window: its frame (points, from the main display's top left), its app, and whether it is a Stage Manager card.
enum BenchLayouts {
  private static func R(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> CGRect { CGRect(x: x, y: y, width: w, height: h) }

  static let all: [String: [(CGRect, String, Bool)]] = [
    "world3": [(R(-1250, -880, 760, 480), "Safari", false), (R(-150, -980, 420, 300), "Notes", false),
               (R(1000, -930, 820, 520), "Code", false), (R(200, 170, 640, 420), "Slack", false), (R(900, 450, 460, 320), "Notes", false),
               (R(1324, 794, 180, 180), "Notification Centre", false)],
    "sm": [(R(300, 40, 1050, 800), "WhatsApp", false), (R(14, 40, 140, 105), "Slack", true), (R(14, 200, 150, 120), "Google Chrome", true),
           (R(14, 375, 140, 115), "Code", true), (R(14, 545, 145, 110), "Claude", true), (R(14, 700, 140, 100), "Spotify", true),
           (R(1330, 790, 170, 170), "Notification Centre", false)],
    "tiled": [(R(16, 40, 732, 926), "Code", false), (R(756, 40, 740, 926), "Google Chrome", false)],
    "cascade": [(R(150, 80, 800, 600), "Google Chrome", false), (R(400, 220, 800, 560), "Slack", false), (R(760, 420, 640, 420), "Terminal", false)],
    "crowded": [(R(30, 50, 420, 300), "Finder", false), (R(470, 60, 380, 260), "Notes", false), (R(880, 40, 600, 380), "Google Chrome", false),
                (R(40, 420, 520, 360), "Slack", false), (R(600, 470, 460, 330), "Terminal", false), (R(1090, 460, 400, 300), "Spotify", false),
                (R(1320, 790, 170, 170), "Notification Centre", false), (R(1140, 790, 170, 170), "Notification Centre", false)],
    "edge": [(R(700, 300, 812, 682), "Code", false), (R(16, 16, 170, 170), "Notification Centre", false), (R(196, 16, 170, 170), "Notification Centre", false)],
    "widgets": [(R(1320, 790, 170, 170), "Notification Centre", false), (R(1320, 600, 170, 170), "Notification Centre", false), (R(40, 60, 344, 170), "Notification Centre", false), (R(1060, 480, 170, 170), "Notification Centre", false), (R(300, 200, 560, 420), "Google Chrome", false)],
    "mine": [(R(16, 193, 100, 130), "Slack", true), (R(16, 337, 118, 149), "Google Chrome", true), (R(16, 512, 118, 155), "Electron", true), (R(16, 675, 118, 147), "Claude", true),
             (R(-7, 263, 66, 82), "WindowManager", false), (R(-7, 441, 66, 82), "WindowManager", false), (R(-7, 622, 66, 82), "WindowManager", false), (R(-7, 777, 66, 82), "WindowManager", false),
             (R(1324, 794, 180, 180), "Notification Centre", false)],
    "big": [(R(16, 193, 100, 130), "Slack", true), (R(16, 337, 118, 149), "Google Chrome", true), (R(16, 512, 118, 155), "Electron", true), (R(16, 675, 118, 147), "Claude", true),
            (R(236, 146, 979, 676), "WhatsApp", false), (R(1324, 794, 180, 180), "Notification Centre", false)],
    "slack": [(R(16, 193, 100, 130), "WhatsApp", true), (R(16, 337, 118, 149), "Google Chrome", true), (R(16, 512, 118, 155), "Electron", true), (R(16, 675, 118, 147), "Claude", true),
              (R(231, 140, 1155, 670), "Slack", false), (R(1324, 794, 180, 180), "Notification Centre", false)],
    "showcase": [(R(250, 190, 620, 410), "Safari", false), (R(840, 430, 470, 320), "Notes", false)],
    "empty": []]
}
#endif
