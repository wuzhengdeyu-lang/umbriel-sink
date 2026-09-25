#include "scene/window_projection.h"

#include "config/config.h"
#include "output/output.h"
#include "scene/border_rect.h"
#include "scene/color.h"
#include "scene/surface_blur.h"
#include "scene/surface_shadow.h"
#include "server/server.h"
#include "server/wine_color_manager.h"
#include "view/view.h"

#include <algorithm>
#include <cmath>
#include <ranges>

// clang-format off
#include "wlr.h"
#include <umbrielfx/render/effect.h>
// clang-format on

namespace umbriel {

  namespace {

    bool rejectInput(wlr_scene_buffer* /*buffer*/, double* /*sx*/, double* /*sy*/) { return false; }

    wlr_scene_buffer* sourceBufferForSurface(wlr_scene_node* node, wlr_surface* surface) {
      if (node->type == WLR_SCENE_NODE_BUFFER) {
        wlr_scene_buffer* buffer = wlr_scene_buffer_from_node(node);
        wlr_scene_surface* sceneSurface = wlr_scene_surface_try_from_buffer(buffer);
        return sceneSurface != nullptr && sceneSurface->surface == surface ? buffer : nullptr;
      }
      if (node->type != WLR_SCENE_NODE_TREE) {
        return nullptr;
      }
      wlr_scene_tree* tree = wlr_scene_tree_from_node(node);
      wlr_scene_node* child = nullptr;
      wl_list_for_each(child, &tree->children, link) {
        if (wlr_scene_buffer* found = sourceBufferForSurface(child, surface)) {
          return found;
        }
      }
      return nullptr;
    }

    int animatedPixel(double value) { return static_cast<int>(std::lround(value)); }

  } // namespace

  WindowProjection::WindowProjection(
      Server& server, View& view, wlr_scene_tree* parent, ChangedCallback changed, bool mirrorAnimationShaders
  )
      : m_server(&server), m_view(&view), m_changed(std::move(changed)),
        m_borderColor(config().colors.border.unfocused), m_mirrorAnimationShaders(mirrorAnimationShaders) {
    m_tree = wlr_scene_tree_create(parent);
    if (m_tree == nullptr) {
      return;
    }
    m_effectTree = wlr_scene_tree_create(m_tree);
    if (m_effectTree == nullptr) {
      wlr_scene_node_destroy(&m_tree->node);
      m_tree = nullptr;
      return;
    }
    float inner[4];
    float outer[4];
    premultiplied(inner, m_borderColor, 1.0F);
    premultiplied(outer, config().colors.border.outer, 1.0F);
    m_border = wlr_scene_border_create(m_effectTree, inner, outer);
    m_blur = std::make_unique<SurfaceBlur>();
    m_shadow = std::make_unique<SurfaceShadow>();
    wlr_scene_node_set_enabled(&m_tree->node, false);
    m_view->registerProjection(this);
    syncSurfaces();
  }

  WindowProjection::~WindowProjection() {
    if (m_view != nullptr) {
      m_view->unregisterProjection(this);
    }
    for (const auto& entry : m_surfaces) {
      wl_list_remove(&entry->commit.link);
      wl_list_remove(&entry->destroy.link);
      wl_list_remove(&entry->outputSample.link);
      wl_list_remove(&entry->frameDone.link);
    }
    m_surfaces.clear();
    m_blur.reset();
    if (m_shadow != nullptr) {
      m_shadow->reset();
    }
    m_shadow.reset();
    if (m_tree != nullptr) {
      wlr_scene_node_destroy(&m_tree->node);
      m_tree = nullptr;
      m_effectTree = nullptr;
      m_border = nullptr;
    }
  }

  void WindowProjection::enumerateSurface(wlr_surface* surface, int sx, int sy, void* data) {
    auto* context = static_cast<EnumerateContext*>(data);
    context->projection->addOrSyncSurface(surface, sx, sy, context->popup);
  }

  void WindowProjection::syncSurfaces() {
    if (m_tree == nullptr
        || m_view == nullptr
        || m_view->toplevel() == nullptr
        || m_view->toplevel()->base == nullptr) {
      return;
    }
    for (const auto& entry : m_surfaces) {
      entry->seen = false;
    }
    EnumerateContext normal{.projection = this, .popup = false};
    wlr_surface_for_each_surface(m_view->toplevel()->base->surface, enumerateSurface, &normal);
    EnumerateContext popup{.projection = this, .popup = true};
    wlr_xdg_surface_for_each_popup_surface(m_view->toplevel()->base, enumerateSurface, &popup);

    std::vector<ProjectedSurface*> stale;
    for (const auto& entry : m_surfaces) {
      if (!entry->seen) {
        stale.push_back(entry.get());
      }
    }
    for (ProjectedSurface* entry : stale) {
      destroySurface(entry);
    }
    applyGeometry();
  }

  void WindowProjection::addOrSyncSurface(wlr_surface* surface, int sx, int sy, bool popup) {
    const auto found =
        std::ranges::find_if(m_surfaces, [surface](const auto& entry) { return entry->surface == surface; });
    if (found != m_surfaces.end()) {
      ProjectedSurface& entry = **found;
      entry.sx = sx;
      entry.sy = sy;
      entry.popup = popup;
      entry.seen = true;
      entry.sourceBuffer = sourceBufferForSurface(&m_view->sceneTree()->node, surface);
      syncBuffer(entry);
      return;
    }

    wlr_scene_buffer* buffer = wlr_scene_buffer_create(m_effectTree, nullptr);
    if (buffer == nullptr) {
      return;
    }
    auto entry = std::make_unique<ProjectedSurface>();
    entry->projection = this;
    entry->surface = surface;
    entry->sourceBuffer = sourceBufferForSurface(&m_view->sceneTree()->node, surface);
    entry->buffer = buffer;
    entry->sx = sx;
    entry->sy = sy;
    entry->root = surface == m_view->toplevel()->base->surface;
    entry->popup = popup;
    entry->seen = true;
    wlr_scene_buffer_set_filter_mode(buffer, WLR_SCALE_FILTER_BILINEAR);
    buffer->point_accepts_input = rejectInput;
    entry->commit.notify = onSurfaceCommit;
    wl_signal_add(&surface->events.commit, &entry->commit);
    entry->destroy.notify = onSurfaceDestroy;
    wl_signal_add(&surface->events.destroy, &entry->destroy);
    entry->outputSample.notify = onBufferOutputSample;
    wl_signal_add(&buffer->events.output_sample, &entry->outputSample);
    entry->frameDone.notify = onBufferFrameDone;
    wl_signal_add(&buffer->events.frame_done, &entry->frameDone);
    syncBuffer(*entry);
    m_surfaces.push_back(std::move(entry));
    if (m_border != nullptr) {
      wlr_scene_node_raise_to_top(&m_border->node);
    }
  }

  void WindowProjection::syncBuffer(ProjectedSurface& entry) {
    wlr_surface* surface = entry.surface;
    if (surface == nullptr || entry.buffer == nullptr) {
      return;
    }
    entry.sourceBuffer = sourceBufferForSurface(&m_view->sceneTree()->node, surface);
    wlr_buffer* committed = surface->buffer != nullptr ? &surface->buffer->base : nullptr;
    wlr_scene_buffer_set_buffer_options options{
        .damage = committed != nullptr ? &surface->buffer_damage : nullptr,
        .wait_timeline = nullptr,
        .wait_point = 0,
    };
    if (wlr_linux_drm_syncobj_surface_v1_state* sync = wlr_linux_drm_syncobj_v1_get_surface_state(surface)) {
      options.wait_timeline = sync->acquire_timeline;
      options.wait_point = sync->acquire_point;
    }
    wlr_scene_buffer_set_buffer_with_options(entry.buffer, committed, &options);

    wlr_fbox source{};
    wlr_surface_get_buffer_source_box(surface, &source);
    wlr_scene_buffer_set_source_box(entry.buffer, &source);
    wlr_scene_buffer_set_dest_size(entry.buffer, surface->current.width, surface->current.height);
    wlr_scene_buffer_set_transform(entry.buffer, surface->current.transform);
    wlr_scene_buffer_set_opaque_region(entry.buffer, &surface->opaque_region);
    if (entry.sourceBuffer != nullptr) {
      wlr_scene_buffer_set_transfer_function(entry.buffer, entry.sourceBuffer->transfer_function);
      wlr_scene_buffer_set_primaries(entry.buffer, entry.sourceBuffer->primaries);
      wlr_scene_buffer_set_luminance_multiplier(entry.buffer, entry.sourceBuffer->luminance_multiplier);
      wlr_scene_buffer_set_color_encoding(entry.buffer, entry.sourceBuffer->color_encoding);
      wlr_scene_buffer_set_color_range(entry.buffer, entry.sourceBuffer->color_range);
    }
    if (WineColorManager* manager = m_server->wineColorManager()) {
      manager->applySurfaceDescriptionToBuffer(surface, entry.buffer);
    }
  }

  void WindowProjection::onSurfaceCommit(wl_listener* listener, void* /*data*/) {
    ProjectedSurface* entry = nullptr;
    entry = wl_container_of(listener, entry, commit);
    WindowProjection* projection = entry->projection;
    projection->syncSurfaces();
    if (projection->m_changed) {
      projection->m_changed();
    }
    projection->scheduleFrame();
  }

  void WindowProjection::onSurfaceDestroy(wl_listener* listener, void* /*data*/) {
    ProjectedSurface* entry = nullptr;
    entry = wl_container_of(listener, entry, destroy);
    entry->projection->destroySurface(entry);
  }

  void WindowProjection::onBufferOutputSample(wl_listener* listener, void* data) {
    ProjectedSurface* entry = nullptr;
    entry = wl_container_of(listener, entry, outputSample);
    auto* event = static_cast<wlr_scene_output_sample_event*>(data);
    wlr_output* output = event->output->output;
    if (event->direct_scanout) {
      wlr_presentation_surface_scanned_out_on_output(entry->surface, output);
    } else {
      wlr_presentation_surface_textured_on_output(entry->surface, output);
    }
    if (wlr_linux_drm_syncobj_surface_v1_state* sync = wlr_linux_drm_syncobj_v1_get_surface_state(entry->surface);
        sync != nullptr && event->release_timeline != nullptr) {
      wlr_linux_drm_syncobj_v1_state_add_release_point(
          sync, event->release_timeline, event->release_point, output->event_loop
      );
    }
  }

  void WindowProjection::onBufferFrameDone(wl_listener* listener, void* data) {
    ProjectedSurface* entry = nullptr;
    entry = wl_container_of(listener, entry, frameDone);
    auto* event = static_cast<wlr_scene_frame_done_event*>(data);
    wlr_surface_send_frame_done(entry->surface, &event->when);
  }

  void WindowProjection::destroySurface(ProjectedSurface* entry) {
    if (entry == nullptr) {
      return;
    }
    wl_list_remove(&entry->commit.link);
    wl_list_remove(&entry->destroy.link);
    wl_list_remove(&entry->outputSample.link);
    wl_list_remove(&entry->frameDone.link);
    if (entry->buffer != nullptr) {
      wlr_scene_node_destroy(&entry->buffer->node);
      entry->buffer = nullptr;
    }
    std::erase_if(m_surfaces, [entry](const auto& candidate) { return candidate.get() == entry; });
  }

  void WindowProjection::setBox(const wlr_box& box) {
    m_x.snap(box.x);
    m_y.snap(box.y);
    m_width.snap(std::max(1, box.width));
    m_height.snap(std::max(1, box.height));
    applyGeometry();
  }

  void WindowProjection::setOpacity(float opacity) {
    m_opacity.snap(std::clamp(static_cast<double>(opacity), 0.0, 1.0));
    applyOpacity();
  }

  void WindowProjection::setBorderColor(const std::array<float, 4>& color) {
    m_borderColor = color;
    applyOpacity();
  }

  void WindowProjection::setEnabled(bool enabled) {
    m_enabled = enabled;
    if (m_tree != nullptr) {
      wlr_scene_node_set_enabled(&m_tree->node, enabled && m_opacity.current() > 0.001);
    }
    applySelfBlur();
  }

  void WindowProjection::setDepth(float depth) {
    m_depth = std::clamp(depth, 0.0F, 1.0F);
    applySelfBlur();
  }

  void WindowProjection::setSelfBlurEnabled(bool enabled) {
    m_selfBlurEnabled = enabled;
    applySelfBlur();
  }

  void WindowProjection::animateTo(const wlr_box& box, float opacity, int durationMs, const AnimationCurve& curve) {
    const double targetOpacity = std::clamp(static_cast<double>(opacity), 0.0, 1.0);
    if (durationMs <= 0) {
      setBox(box);
      setOpacity(opacity);
      return;
    }
    m_x.retarget(box.x, durationMs, curve);
    m_y.retarget(box.y, durationMs, curve);
    m_width.retarget(std::max(1, box.width), durationMs, curve);
    m_height.retarget(std::max(1, box.height), durationMs, curve);
    m_opacity.retarget(targetOpacity, durationMs, curve);
    m_enabled = true;
    if (m_tree != nullptr) {
      wlr_scene_node_set_enabled(&m_tree->node, true);
    }
    scheduleFrame();
  }

  bool WindowProjection::tick(uint64_t nowMsec) {
    const bool changed = m_x.tick(nowMsec)
        | m_y.tick(nowMsec)
        | m_width.tick(nowMsec)
        | m_height.tick(nowMsec)
        | m_opacity.tick(nowMsec);
    if (changed) {
      applyGeometry();
      scheduleFrame();
    }
    return animating();
  }

  bool WindowProjection::animating() const {
    return m_x.animating() || m_y.animating() || m_width.animating() || m_height.animating() || m_opacity.animating();
  }

  wlr_scene_node* WindowProjection::borderNode() const { return m_border != nullptr ? &m_border->node : nullptr; }

  void WindowProjection::applyGeometry() {
    if (m_tree == nullptr || m_view == nullptr) {
      return;
    }
    m_box = {
        .x = animatedPixel(m_x.current()),
        .y = animatedPixel(m_y.current()),
        .width = std::max(1, animatedPixel(m_width.current())),
        .height = std::max(1, animatedPixel(m_height.current())),
    };
    wlr_scene_node_set_position(&m_tree->node, m_box.x, m_box.y);

    const wlr_box& geometry = m_view->toplevel()->base->geometry;
    if (geometry.width <= 0 || geometry.height <= 0) {
      wlr_scene_node_set_enabled(&m_tree->node, false);
      return;
    }
    const double fx = static_cast<double>(m_box.width) / geometry.width;
    const double fy = static_cast<double>(m_box.height) / geometry.height;
    const auto& appearance = config().appearance;
    const auto scaledWidth = [fx, fy](int width) {
      const double scale = std::min(fx, fy);
      return width > 0 ? std::max(1, static_cast<int>(std::lround(width * scale))) : 0;
    };
    const int innerWidth = scaledWidth(appearance.borderWidth);
    const int outerWidth = scaledWidth(appearance.outerBorderWidth);
    const int radius = static_cast<int>(std::lround(appearance.cornerRadius * std::min(fx, fy)));
    const int surfaceRadius = nestedRadius(radius, innerWidth + outerWidth);
    const bool decorated = !m_view->toplevel()->current.fullscreen && !m_view->maximizedToEdges();
    const bool borderVisible = decorated && innerWidth + outerWidth > 0;
    if (m_border != nullptr) {
      wlr_scene_node_set_enabled(&m_border->node, borderVisible);
      if (borderVisible) {
        applyBorderGeometry(
            m_border, makeBorderRing(m_box.width, m_box.height, radius, innerWidth, outerWidth), innerWidth, outerWidth
        );
      }
    }
    if (m_shadow != nullptr) {
      m_shadow->update(
          m_tree, m_box.width, m_box.height, borderVisible ? innerWidth + outerWidth : 0, borderVisible ? radius : 0
      );
      m_shadow->setAnimationSource(&m_tree->node);
    }

    bool blurUpdated = false;
    for (const auto& entry : m_surfaces) {
      wlr_surface* surface = entry->surface;
      if (entry->buffer == nullptr
          || surface == nullptr
          || surface->current.width <= 0
          || surface->current.height <= 0) {
        continue;
      }
      if (entry->root) {
        wlr_fbox base{};
        wlr_surface_get_buffer_source_box(surface, &base);
        const double bx = base.width / surface->current.width;
        const double by = base.height / surface->current.height;
        wlr_fbox source{
            base.x + geometry.x * bx,
            base.y + geometry.y * by,
            geometry.width * bx,
            geometry.height * by,
        };
        if (source.x < base.x) {
          source.width -= base.x - source.x;
          source.x = base.x;
        }
        if (source.y < base.y) {
          source.height -= base.y - source.y;
          source.y = base.y;
        }
        source.width = std::min(source.width, base.x + base.width - source.x);
        source.height = std::min(source.height, base.y + base.height - source.y);
        if (source.width <= 0 || source.height <= 0) {
          wlr_scene_node_set_enabled(&entry->buffer->node, false);
          continue;
        }
        wlr_scene_node_set_enabled(&entry->buffer->node, true);
        wlr_scene_node_set_position(&entry->buffer->node, 0, 0);
        wlr_scene_buffer_set_source_box(entry->buffer, &source);
        wlr_scene_buffer_set_dest_size(entry->buffer, m_box.width, m_box.height);
        const wlr_box blurBox{0, 0, m_box.width, m_box.height};
        m_blur->setAlpha(1.0F);
        m_blur->update(
            m_effectTree, surface, blurBox, geometry, surfaceRadius, nullptr, m_view->blurOptions(),
            entry->buffer->opacity, entry->buffer
        );
        blurUpdated = true;
      } else {
        const wlr_box destination{
            .x = static_cast<int>(std::lround((entry->sx - geometry.x) * fx)),
            .y = static_cast<int>(std::lround((entry->sy - geometry.y) * fy)),
            .width = std::max(1, static_cast<int>(std::lround(surface->current.width * fx))),
            .height = std::max(1, static_cast<int>(std::lround(surface->current.height * fy))),
        };
        wlr_scene_node_set_enabled(&entry->buffer->node, true);
        wlr_scene_node_set_position(&entry->buffer->node, destination.x, destination.y);
        wlr_scene_buffer_set_dest_size(entry->buffer, destination.width, destination.height);
      }
      const int appliedRadius = entry->popup ? 0 : surfaceRadius;
      const wlr_box cornerBox{-entry->buffer->node.x, -entry->buffer->node.y, m_box.width, m_box.height};
      wlr_scene_buffer_set_corner_radii(entry->buffer, corner_radii_all(appliedRadius));
      wlr_scene_buffer_set_corner_box(entry->buffer, appliedRadius > 0 ? &cornerBox : nullptr);
    }
    if (!blurUpdated && m_blur != nullptr) {
      m_blur->hide();
    }
    if (m_mirrorAnimationShaders) {
      m_view->syncAnimationShaders(m_effectTree, borderNode());
    }
    applyOpacity();
  }

  void WindowProjection::applyOpacity() {
    const float opacity = static_cast<float>(std::clamp(m_opacity.current(), 0.0, 1.0));
    for (const auto& entry : m_surfaces) {
      if (entry->buffer == nullptr) {
        continue;
      }
      const float source = entry->sourceBuffer != nullptr ? entry->sourceBuffer->opacity : m_view->presentedOpacity();
      wlr_scene_buffer_set_opacity(entry->buffer, std::clamp(source * opacity, 0.0F, 1.0F));
    }
    if (m_border != nullptr) {
      float inner[4];
      float outer[4];
      premultiplied(inner, m_borderColor, m_view->presentedOpacity() * opacity);
      premultiplied(outer, config().colors.border.outer, m_view->presentedOpacity() * opacity);
      wlr_scene_border_set_colors(m_border, inner, outer);
    }
    if (m_shadow != nullptr) {
      m_shadow->setAlpha(m_view->presentedOpacity() * opacity);
    }
    if (m_tree != nullptr) {
      wlr_scene_node_set_enabled(&m_tree->node, m_enabled && opacity > 0.001F);
    }
    applySelfBlur();
  }

  void WindowProjection::applySelfBlur() {
    if (m_effectTree == nullptr) {
      return;
    }
    const auto& settings = config().appearance.sink;
    if (!m_selfBlurEnabled || !settings.selfBlur || !m_enabled || m_opacity.current() <= 0.001 || m_depth <= 0.0F) {
      wlr_scene_node_set_self_blur(&m_effectTree->node, nullptr);
      return;
    }
    const fx_self_blur_options options{
        .depth = m_depth,
        .radius = static_cast<float>(settings.blurRadius),
        .samples = static_cast<unsigned>(settings.blurSamples),
    };
    wlr_scene_node_set_self_blur(&m_effectTree->node, &options);
  }

  void WindowProjection::scheduleFrame() const {
    if (m_view != nullptr) {
      if (Output* output = m_view->currentOutput(); output != nullptr && output->wlr() != nullptr) {
        wlr_output_schedule_frame(output->wlr());
      }
    }
  }

  int WindowProjection::snapshot(
      wlr_scene_tree* target, int offsetX, int offsetY, std::vector<BorderSnapshot>& borders
  ) const {
    if (target == nullptr || m_tree == nullptr) {
      return 0;
    }
    int copied = 0;
    for (const auto& entry : m_surfaces) {
      wlr_scene_buffer* source = entry->buffer;
      if (source == nullptr || source->buffer == nullptr || !source->node.enabled) {
        continue;
      }
      wlr_scene_buffer* copy = wlr_scene_buffer_create(target, source->buffer);
      if (copy == nullptr) {
        continue;
      }
      wlr_scene_node_set_position(
          &copy->node, offsetX + m_tree->node.x + source->node.x, offsetY + m_tree->node.y + source->node.y
      );
      if (source->dst_width > 0 && source->dst_height > 0) {
        wlr_scene_buffer_set_dest_size(copy, source->dst_width, source->dst_height);
      }
      if (source->src_box.width > 0 && source->src_box.height > 0) {
        wlr_scene_buffer_set_source_box(copy, &source->src_box);
      }
      wlr_scene_buffer_set_transform(copy, source->transform);
      wlr_scene_buffer_set_corner_radii(copy, source->corners);
      wlr_scene_buffer_set_corner_box(copy, &source->corner_box);
      wlr_scene_buffer_set_opacity(copy, source->opacity);
      wlr_scene_buffer_set_transfer_function(copy, source->transfer_function);
      wlr_scene_buffer_set_primaries(copy, source->primaries);
      wlr_scene_buffer_set_luminance_multiplier(copy, source->luminance_multiplier);
      wlr_scene_buffer_set_color_encoding(copy, source->color_encoding);
      wlr_scene_buffer_set_color_range(copy, source->color_range);
      wlr_scene_buffer_set_filter_mode(copy, WLR_SCALE_FILTER_BILINEAR);
      ++copied;
    }
    if (m_border != nullptr && m_border->node.enabled) {
      wlr_scene_border* copy = wlr_scene_border_create(target, m_border->inner_color, m_border->outer_color);
      if (copy != nullptr) {
        wlr_scene_border_set_geometry(
            copy, m_border->width, m_border->height, m_border->inner_width, m_border->outer_width,
            m_border->clipped_region, m_border->seam_corners, m_border->outer_corners
        );
        wlr_scene_node_set_position(
            &copy->node, offsetX + m_tree->node.x + m_border->node.x, offsetY + m_tree->node.y + m_border->node.y
        );
        BorderSnapshot border{.node = copy, .innerColor = m_borderColor, .outerColor = config().colors.border.outer};
        border.innerColor[3] *= m_view->presentedOpacity() * static_cast<float>(m_opacity.current());
        border.outerColor[3] *= m_view->presentedOpacity() * static_cast<float>(m_opacity.current());
        borders.push_back(border);
      }
    }
    return copied;
  }

} // namespace umbriel
