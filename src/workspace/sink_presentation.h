#pragma once

#include "config/config.h"

#include <algorithm>
#include <cmath>
#include <cstddef>

extern "C" {
#include <wlr/util/box.h>
}

namespace umbriel {

  struct SinkDepthStyle {
    double scale = 0.0;
    float opacity = 0.0F;
    float effectDepth = 1.0F;
    bool visible = false;
  };

  [[nodiscard]] constexpr SinkDepthStyle sinkDepthStyle(const Config::Appearance::Sink& settings, size_t depth) {
    const bool visible = depth < static_cast<size_t>(settings.visibleDepth);
    const auto& level = settings.levels[visible ? depth : static_cast<size_t>(settings.visibleDepth - 1)];
    return {
        .scale = level.scale,
        .opacity = visible ? static_cast<float>(level.opacity) : 0.0F,
        .effectDepth = static_cast<float>(level.blurStrength),
        .visible = visible,
    };
  }

  [[nodiscard]] inline wlr_box sinkProjectionBox(
      int sourceWidth, int sourceHeight, const wlr_box& workArea, const Config::Appearance::Sink& settings, size_t depth
  ) {
    sourceWidth = std::max(1, sourceWidth);
    sourceHeight = std::max(1, sourceHeight);
    const double fit = std::min(
        {1.0, static_cast<double>(workArea.width) / sourceWidth, static_cast<double>(workArea.height) / sourceHeight}
    );
    const double scale = fit * sinkDepthStyle(settings, depth).scale;
    const int width = std::max(1, static_cast<int>(std::lround(sourceWidth * scale)));
    const int height = std::max(1, static_cast<int>(std::lround(sourceHeight * scale)));
    return {
        .x = workArea.x + (workArea.width - width) / 2,
        .y = workArea.y + (workArea.height - height) / 2,
        .width = width,
        .height = height,
    };
  }

} // namespace umbriel
