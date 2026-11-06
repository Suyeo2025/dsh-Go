// The 「鲸游」Live Activity extension (com.colex.dshgo.activity): wires the shared views
// (Runner/WhaleWakeShared/WhaleWakeViews.swift) into ActivityConfiguration. Attributes, views,
// intents and samples are compiled into this target and into Runner from Runner/WhaleWakeShared/.

import ActivityKit
import SwiftUI
import WidgetKit

@main
struct WhaleWakeBundle: WidgetBundle {
  var body: some Widget {
    WhaleWakeLiveActivity()
  }
}

struct WhaleWakeLiveActivity: Widget {
  var body: some WidgetConfiguration {
    ActivityConfiguration(for: WhaleWakeAttributes.self) { context in
      WhaleWakeLockView(attributes: context.attributes, state: context.state, isStale: context.isStale)
    } dynamicIsland: { context in
      let a = context.attributes
      let s = context.state
      let stale = context.isStale
      return DynamicIsland {
        DynamicIslandExpandedRegion(.leading) {
          WhaleWakeExpandedLeading(state: s).padding(.leading, 4)
        }
        DynamicIslandExpandedRegion(.center) {
          WhaleWakeExpandedCenter(attributes: a, state: s, isStale: stale).padding(.top, 6)
        }
        DynamicIslandExpandedRegion(.trailing) {
          WhaleWakeExpandedTrailing(attributes: a, state: s, isStale: stale).padding(.top, 6).padding(.trailing, 4)
        }
        DynamicIslandExpandedRegion(.bottom) {
          WhaleWakeExpandedBottom(attributes: a, state: s, isStale: stale).padding(.horizontal, 4)
        }
      } compactLeading: {
        WhaleWakeCompactLeading(state: s)
      } compactTrailing: {
        WhaleWakeCompactTrailing(attributes: a, state: s, isStale: stale)
      } minimal: {
        WhaleWakeMinimal(state: s)
      }
      .widgetURL(WhaleWakeAttributes.sessionURL(a.sessionId, eventId: s.pending?.eventId))
      .keylineTint(s.color(WhaleWakePalette.dark))
    }
  }
}
