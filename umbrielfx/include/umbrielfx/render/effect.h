#ifndef UMBRIELFX_EFFECT_H
#define UMBRIELFX_EFFECT_H

#include <stdbool.h>

struct wlr_scene_node;

#ifdef __cplusplus
extern "C" {
#endif

// A persistent, damage-driven blur of a scene subtree. Unlike an animation
// shader this effect does not request frames or make the scene continuously
// damaged. The renderer captures the subtree itself, so pixels behind the
// node are never sampled.
struct fx_self_blur_options {
  float depth;
  float radius;
  unsigned samples;
};

// A NULL options pointer, zero depth/radius, or fewer than three samples
// removes the effect. The scene node owns no renderer resource; programs and
// temporary targets belong to the renderer/output and survive node teardown.
void wlr_scene_node_set_self_blur(struct wlr_scene_node* node, const struct fx_self_blur_options* options);

#ifdef __cplusplus
}
#endif

#endif
