#include "workspace/sink_presentation.h"

#include "check.h"

using namespace umbriel;

UMBRIEL_TEST(depthMapsTopTwoEntriesOntoVisibleHorizon) {
  const Config::Appearance::Sink settings;
  CHECK(sinkDepthStyle(settings, 0).visible);
  CHECK_EQ(sinkDepthStyle(settings, 0).scale, 0.93);
  CHECK_EQ(sinkDepthStyle(settings, 0).opacity, 0.82F);
  CHECK_EQ(sinkDepthStyle(settings, 0).effectDepth, 0.5F);
  CHECK(sinkDepthStyle(settings, 1).visible);
  CHECK_EQ(sinkDepthStyle(settings, 1).scale, 0.85);
  CHECK_EQ(sinkDepthStyle(settings, 1).opacity, 0.45F);
  CHECK_EQ(sinkDepthStyle(settings, 1).effectDepth, 1.0F);
  CHECK(!sinkDepthStyle(settings, 2).visible);
  CHECK_EQ(sinkDepthStyle(settings, 2).opacity, 0.0F);
  CHECK(!sinkDepthStyle(settings, 99).visible);
}

UMBRIEL_TEST(configuredHorizonAndLevelsChangeProjectionStyle) {
  Config::Appearance::Sink settings;
  settings.visibleDepth = 3;
  settings.levels[2] = {.scale = 0.7, .opacity = 0.3, .blurStrength = 0.8};
  CHECK(sinkDepthStyle(settings, 2).visible);
  CHECK_EQ(sinkDepthStyle(settings, 2).scale, 0.7);
  CHECK_EQ(sinkDepthStyle(settings, 2).opacity, 0.3F);
  CHECK_EQ(sinkDepthStyle(settings, 2).effectDepth, 0.8F);
  CHECK(!sinkDepthStyle(settings, 3).visible);
  CHECK_EQ(sinkDepthStyle(settings, 3).scale, 0.7);
  settings.visibleDepth = 1;
  CHECK(!sinkDepthStyle(settings, 1).visible);
  CHECK_EQ(sinkDepthStyle(settings, 1).scale, 0.93);
}

UMBRIEL_TEST(projectionRemainsCenteredAndNeverEnlargesItsSource) {
  const wlr_box workArea{.x = 100, .y = 50, .width = 1000, .height = 800};
  const Config::Appearance::Sink settings;
  const wlr_box top = sinkProjectionBox(500, 400, workArea, settings, 0);
  CHECK_EQ(top.x, 367);
  CHECK_EQ(top.y, 264);
  CHECK_EQ(top.width, 465);
  CHECK_EQ(top.height, 372);

  const wlr_box oversized = sinkProjectionBox(2000, 1000, workArea, settings, 1);
  CHECK_EQ(oversized.width, 850);
  CHECK_EQ(oversized.height, 425);
  CHECK_EQ(oversized.x, workArea.x + (workArea.width - oversized.width) / 2);
  CHECK_EQ(oversized.y, workArea.y + (workArea.height - oversized.height) / 2);
}

UMBRIEL_TEST(degenerateSourceDimensionsStillProduceAValidProjection) {
  const wlr_box box = sinkProjectionBox(0, 0, wlr_box{.x = 3, .y = 4, .width = 20, .height = 10}, {}, 0);
  CHECK(box.width >= 1);
  CHECK(box.height >= 1);
}

int main() { return RUN_TESTS(); }
