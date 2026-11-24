// The Web Audio engine shared by both hosts. The runtime's TypeScript objects are thin handles
// into this: nodes, buffers and parameters live here, and one engine renders both a real-time
// AudioContext (from the platform's audio callback or its own null-sink thread) and an
// OfflineAudioContext (synchronously, into the caller's bytes). Both paths run the same graph so
// a render is the same render wherever it runs.
//
// Threading. The script thread never processes audio. It writes fixed-size commands into a single
// producer/single consumer ring; the audio thread drains it at the start of each 128-frame
// quantum. Scalar parameters are also published atomically so a `.value` read never waits for the
// next quantum. Nodes are allocated from a fixed pool by the script thread and returned to it by
// the audio thread once a release has been applied, so the real-time thread never allocates or
// frees. Events that need the script thread (a source ending) go through their own ring, which
// the runtime polls once a frame.

#include <math.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#ifdef __APPLE__
#include <AudioToolbox/AudioToolbox.h>
#include <AudioUnit/AudioUnit.h>
#include <CoreAudio/CoreAudio.h>
#elif defined(__linux__)
#include <alsa/asoundlib.h>
#include <sched.h>
#include <stdarg.h>
#endif

#include "audio.h"

// ---------------------------------------------------------------------------
// Sizes

#define CMD_RING 16384
#define EVENT_RING 2048
#define MAX_CONTEXTS 32
#define MAX_TRASH 8192
#define MAX_PTRS 8192

// Node types, mirrored by TYPE_* in runtime/audio/native.ts.
enum {
  NODE_DESTINATION = 0,
  NODE_GAIN = 1,
  NODE_OSCILLATOR = 2,
  NODE_BUFFER_SOURCE = 3,
  NODE_BIQUAD = 4,
  NODE_STEREO_PANNER = 5,
  NODE_ANALYSER = 6,
  NODE_CONSTANT_SOURCE = 7,
  NODE_PANNER = 8,
  NODE_DELAY = 9,
  NODE_COMPRESSOR = 10,
  NODE_CONVOLVER = 11,
};

// Param kinds, mirrored by PARAM_* in runtime/audio/param.ts.
enum { PARAM_GAIN = 0 };

// Command kinds.
enum {
  CMD_INIT = 1,
  CMD_RELEASE,
  CMD_CONNECT,
  CMD_DISCONNECT,
  CMD_PARAM_EVENT,
  CMD_SET_BUFFER,
  CMD_SOURCE_START,
  CMD_SOURCE_STOP,
  CMD_LOOP,
  CMD_OSC_TYPE,
  CMD_BIQUAD_TYPE,
  CMD_PARAM_CANCEL,
  CMD_PANNER_CONFIG,
  CMD_CONV_BUFFER,
};

// Parameter event kinds, mirrored by EV_* in runtime/audio/param.ts.
enum {
  EV_SET_VALUE = 0,
  EV_LINEAR_RAMP = 1,
  EV_EXP_RAMP = 2,
  EV_SET_TARGET = 3,
};

// Events the engine reports to the script thread.
enum { AUDIO_EVENT_ENDED = 1 };

typedef struct ParamEvent {
  int kind;
  double t0;
  double t1;
  double value;
  double aux; // a setTarget's time constant, in seconds
  struct ParamEvent *next;
} ParamEvent;

typedef struct {
  int count;
  ParamEvent *head;
  double value;
  int in_ramp;
  int ramp_exp;
  double r0, r1, v0, v1;
  int in_target;
  double target_v, target_v0, target_t0, target_tc;
  _Atomic int current_bits;
} Param;

typedef struct Node {
  int type;
  int active;
  int inputs[AUDIO_MAX_INPUTS];
  int input_count;
  Param params[AUDIO_MAX_PARAMS];
  float out[2][AUDIO_QUANTUM];
  float in[2][AUDIO_QUANTUM];

  // Scheduled sources: oscillator and constant-source start and stop, and their waveform.
  int started;
  int has_stop;
  int ended;
  double start_frame;
  double stop_frame;
  double phase;
  int osc_type;

  // AudioBufferSourceNode.
  int buffer;
  double pos;
  int loop;
  double loop_start;
  double loop_end;
  int has_duration;
  double duration_end;

  // BiquadFilterNode.
  int biquad_type;
  double b0, b1, b2, a1, a2;
  double z1[2], z2[2];

  // PannerNode.
  int panning_model;
  int distance_model;
  double ref_distance;
  double max_distance;
  double rolloff;
  double cone_inner;
  double cone_outer;
  double cone_gain;

  // DelayNode.
  float *delay_left;
  float *delay_right;
  int delay_length;
  int delay_write;

  // DynamicsCompressorNode.
  double comp_envelope;
  _Atomic int reduction_bits;

  // ConvolverNode.
  int conv_buffer;
  int conv_normalize;
  double conv_scale;
  float *conv_left;
  float *conv_right;
  int conv_length;
  int conv_write;

  // AnalyserNode: a ring of the latest mono samples, written under a seqlock.
  float *ring;
  _Atomic uint32_t ring_write;
  _Atomic uint32_t ring_seq;
} Node;

typedef struct {
  int kind;
  int a, b, c, d;
  double x, y, z;
  void *ptr;
} Cmd;

/** A delay node's two delay lines, made and sized on the script thread. */
typedef struct {
  float *left;
  float *right;
  int length;
} DelayData;

/** A convolver's input history, sized to its impulse on the script thread. */
typedef struct {
  float *left;
  float *right;
  int length;
} ConvolverData;

/** A panner's scalar settings, which move as one. */
typedef struct {
  int panning_model;
  int distance_model;
  double ref_distance;
  double max_distance;
  double rolloff;
  double cone_inner;
  double cone_outer;
  double cone_gain;
} PannerConfig;

typedef struct {
  int32_t node;
  int32_t kind;
} AudioEvent;

struct AudioContext {
  int id;
  int offline;
  int channels;
  double rate;
  double device_rate;

  _Atomic int running;
  _Atomic int closed;
  _Atomic uint64_t rendered;

  Node nodes[AUDIO_MAX_NODES];
  AudioBufferData *buffers[AUDIO_MAX_BUFFERS];

  Cmd cmds[CMD_RING];
  _Atomic uint32_t cmd_head;
  _Atomic uint32_t cmd_tail;

  float ql[AUDIO_QUANTUM];
  float qr[AUDIO_QUANTUM];
  int qpos;
  int qlen;
  uint64_t timestamp;

  // Rings the audio thread writes and the script thread reads: released node ids, parameter
  // events it is done with, and memory it has finished reading.
  int free_ids[AUDIO_MAX_NODES];
  _Atomic uint32_t free_head;
  _Atomic uint32_t free_tail;

  ParamEvent *trash[MAX_TRASH];
  _Atomic uint32_t trash_head;
  _Atomic uint32_t trash_tail;
  void *ptrs[MAX_PTRS];
  _Atomic uint32_t ptr_head;
  _Atomic uint32_t ptr_tail;

  AudioEvent events[EVENT_RING];
  _Atomic uint32_t ev_head;
  _Atomic uint32_t ev_tail;

  int order[AUDIO_MAX_NODES];
  int order_count;
  int order_dirty;

  // A context whose rate differs from the device's resamples on the way out. The next context
  // frame is produced lazily and interpolated between the last two.
  double rs_phase;
  float rs_prev_l, rs_prev_r, rs_next_l, rs_next_r;
  int rs_started;

  pthread_t thread;
  _Atomic int thread_stop;
  int thread_live;
  void *platform;
};

static void push_free_node(AudioContext *c, int id);

static AudioContext *g_contexts[MAX_CONTEXTS];
static pthread_mutex_t g_contexts_lock = PTHREAD_MUTEX_INITIALIZER;

// ---------------------------------------------------------------------------
// Small helpers

static double clampd(double v, double lo, double hi) {
  return v < lo ? lo : v > hi ? hi : v;
}

static void sleep_seconds(double seconds) {
  if (seconds <= 0) return;
  struct timespec ts;
  ts.tv_sec = (time_t)seconds;
  ts.tv_nsec = (long)((seconds - (double)ts.tv_sec) * 1e9);
  nanosleep(&ts, NULL);
}

static void push_trash(AudioContext *c, ParamEvent *e) {
  uint32_t tail = atomic_load_explicit(&c->trash_tail, memory_order_relaxed);
  uint32_t head = atomic_load_explicit(&c->trash_head, memory_order_acquire);
  // A full ring drops the event: leaking one small allocation is better than making the audio
  // thread wait for the script thread.
  if (tail - head >= MAX_TRASH) return;
  c->trash[tail % MAX_TRASH] = e;
  atomic_store_explicit(&c->trash_tail, tail + 1, memory_order_release);
}

static void push_ptr(AudioContext *c, void *p) {
  if (p == NULL) return;
  uint32_t tail = atomic_load_explicit(&c->ptr_tail, memory_order_relaxed);
  uint32_t head = atomic_load_explicit(&c->ptr_head, memory_order_acquire);
  if (tail - head >= MAX_PTRS) return;
  c->ptrs[tail % MAX_PTRS] = p;
  atomic_store_explicit(&c->ptr_tail, tail + 1, memory_order_release);
}

/** Frees what the audio thread handed back. Runs on the script thread. */
static void collect(AudioContext *c) {
  uint32_t tail = atomic_load_explicit(&c->trash_tail, memory_order_acquire);
  uint32_t head = atomic_load_explicit(&c->trash_head, memory_order_relaxed);
  while (head != tail) {
    free(c->trash[head % MAX_TRASH]);
    head++;
  }
  atomic_store_explicit(&c->trash_head, head, memory_order_release);
  tail = atomic_load_explicit(&c->ptr_tail, memory_order_acquire);
  head = atomic_load_explicit(&c->ptr_head, memory_order_relaxed);
  while (head != tail) {
    free(c->ptrs[head % MAX_PTRS]);
    head++;
  }
  atomic_store_explicit(&c->ptr_head, head, memory_order_release);
}

static void push_event(AudioContext *c, int node, int kind) {
  uint32_t tail = atomic_load_explicit(&c->ev_tail, memory_order_relaxed);
  uint32_t head = atomic_load_explicit(&c->ev_head, memory_order_acquire);
  if (tail - head >= EVENT_RING) return;
  c->events[tail % EVENT_RING].node = node;
  c->events[tail % EVENT_RING].kind = kind;
  atomic_store_explicit(&c->ev_tail, tail + 1, memory_order_release);
}

// ---------------------------------------------------------------------------
// Parameters

static void param_init(Param *p, double value) {
  memset(p, 0, sizeof(*p));
  p->value = value;
  float f = (float)value;
  int bits;
  memcpy(&bits, &f, sizeof(bits));
  atomic_store_explicit(&p->current_bits, bits, memory_order_relaxed);
}

static double param_at(AudioContext *c, Param *p, double frame, double rate) {
  while (p->head != NULL && frame + 1e-9 >= p->head->t0) {
    ParamEvent *e = p->head;
    p->head = e->next;
    p->count--;
    if (e->kind == EV_SET_VALUE) {
      p->value = e->value;
      p->in_ramp = 0;
      p->in_target = 0;
    } else if (e->kind == EV_LINEAR_RAMP || e->kind == EV_EXP_RAMP) {
      p->in_ramp = 1;
      p->in_target = 0;
      p->ramp_exp = e->kind == EV_EXP_RAMP;
      p->r0 = e->t0;
      p->r1 = e->t1;
      p->v0 = p->value;
      p->v1 = e->value;
      if (p->r1 <= p->r0) {
        p->value = e->value;
        p->in_ramp = 0;
      }
    } else if (e->kind == EV_SET_TARGET) {
      p->in_target = 1;
      p->in_ramp = 0;
      p->target_v = e->value;
      p->target_v0 = p->value;
      p->target_t0 = e->t0;
      p->target_tc = e->aux > 0 ? e->aux : 1e-9;
    }
    // The event's own storage goes back to the script thread, which frees it.
    push_trash(c, e);
  }
  if (p->in_ramp) {
    if (frame >= p->r1) {
      p->value = p->v1;
      p->in_ramp = 0;
    } else if (p->r1 > p->r0) {
      double u = (frame - p->r0) / (p->r1 - p->r0);
      if (u < 0) u = 0;
      if (p->ramp_exp) {
        if (p->v0 != 0 && p->v1 != 0 && ((p->v0 < 0) == (p->v1 < 0))) {
          p->value = p->v0 * pow(p->v1 / p->v0, u);
        } else {
          p->value = 0;
        }
      } else {
        p->value = p->v0 + (p->v1 - p->v0) * u;
      }
    }
  } else if (p->in_target) {
    double dt = frame - p->target_t0;
    if (dt < 0) dt = 0;
    p->value = p->target_v + (p->target_v0 - p->target_v) * exp(-dt / (p->target_tc * rate));
  }
  return p->value;
}

/** The value one sample before `frame`, used to hold a parameter at a cancel time. */
static double param_value_now(Param *p, double frame, double rate) {
  if (p->head == NULL && !p->in_ramp && !p->in_target) return p->value;
  // Evaluate on a copy-shaped path: the events already consumed are the past ones, so a plain
  // evaluation at the current frame is what the parameter holds now.
  if (p->in_ramp && p->r1 > p->r0) {
    double u = clampd((frame - p->r0) / (p->r1 - p->r0), 0, 1);
    if (p->ramp_exp) {
      if (p->v0 != 0 && p->v1 != 0 && ((p->v0 < 0) == (p->v1 < 0))) return p->v0 * pow(p->v1 / p->v0, u);
      return 0;
    }
    return p->v0 + (p->v1 - p->v0) * u;
  }
  if (p->in_target) {
    double dt = frame - p->target_t0;
    if (dt < 0) dt = 0;
    return p->target_v + (p->target_v0 - p->target_v) * exp(-dt / (p->target_tc * rate));
  }
  return p->value;
}

static void param_insert(Param *p, ParamEvent *e, double now) {
  if (e->kind == EV_LINEAR_RAMP || e->kind == EV_EXP_RAMP) {
    // A ramp starts where the event before it ends, or now when it is first.
    double t0 = now;
    ParamEvent *before = NULL;
    for (ParamEvent *it = p->head; it != NULL; it = it->next) {
      double end = (it->kind == EV_LINEAR_RAMP || it->kind == EV_EXP_RAMP) ? it->t1 : it->t0;
      if (end <= e->t1) before = it;
      else break;
    }
    if (before != NULL) t0 = (before->kind == EV_LINEAR_RAMP || before->kind == EV_EXP_RAMP) ? before->t1 : before->t0;
    if (t0 > e->t1) t0 = e->t1;
    e->t0 = t0;
  }
  double key = (e->kind == EV_LINEAR_RAMP || e->kind == EV_EXP_RAMP) ? e->t1 : e->t0;
  ParamEvent **pp = &p->head;
  while (*pp != NULL) {
    ParamEvent *it = *pp;
    double it_key = (it->kind == EV_LINEAR_RAMP || it->kind == EV_EXP_RAMP) ? it->t1 : it->t0;
    if (it_key > key) break;
    pp = &it->next;
  }
  e->next = *pp;
  *pp = e;
  p->count++;
}

static void param_cancel(AudioContext *c, Param *p, double time, int hold, double rate) {
  ParamEvent **pp = &p->head;
  while (*pp != NULL) {
    ParamEvent *e = *pp;
    if (e->t0 + 1e-9 >= time) {
      *pp = e->next;
      p->count--;
      push_trash(c, e);
    } else {
      pp = &e->next;
    }
  }
  if (p->in_ramp && p->r1 + 1e-9 >= time) {
    p->value = param_value_now(p, time, rate);
    p->in_ramp = 0;
  }
  if (hold && p->in_target) {
    p->value = param_value_now(p, time, rate);
    p->in_target = 0;
  }
}

// ---------------------------------------------------------------------------
// Nodes

static double node_param(AudioContext *c, Node *n, int index, double frame, double rate) {
  if (index < 0 || index >= AUDIO_MAX_PARAMS) return 0;
  return param_at(c, &n->params[index], frame, rate);
}

static void node_init(AudioContext *c, Node *n, int type, void *data) {
  (void)c;
  memset(n, 0, sizeof(*n));
  n->type = type;
  n->active = 1;
  n->buffer = -1;
  n->osc_type = 0; // sine
  n->biquad_type = 0; // lowpass
  n->loop_end = -1;
  for (int i = 0; i < AUDIO_MAX_PARAMS; i++) param_init(&n->params[i], 0);
  switch (type) {
    case NODE_DESTINATION:
      // The listener shares the destination's otherwise unused parameters.
      param_init(&n->params[0], 0); // positionX
      param_init(&n->params[1], 0); // positionY
      param_init(&n->params[2], 0); // positionZ
      param_init(&n->params[3], 0); // forwardX
      param_init(&n->params[4], 0); // forwardY
      param_init(&n->params[5], -1); // forwardZ
      param_init(&n->params[6], 0); // upX
      param_init(&n->params[7], 1); // upY
      param_init(&n->params[8], 0); // upZ
      break;
    case NODE_GAIN:
      param_init(&n->params[0], 1);
      break;
    case NODE_OSCILLATOR:
      param_init(&n->params[0], 440);
      param_init(&n->params[1], 0);
      break;
    case NODE_BUFFER_SOURCE:
      param_init(&n->params[0], 1);
      param_init(&n->params[1], 0);
      n->loop_start = 0;
      n->loop_end = -1;
      break;
    case NODE_BIQUAD:
      param_init(&n->params[0], 350);
      param_init(&n->params[1], 0);
      param_init(&n->params[2], 1);
      param_init(&n->params[3], 0);
      break;
    case NODE_STEREO_PANNER:
      param_init(&n->params[0], 0);
      break;
    case NODE_CONSTANT_SOURCE:
      param_init(&n->params[0], 1);
      break;
    case NODE_PANNER:
      param_init(&n->params[0], 0); // positionX
      param_init(&n->params[1], 0); // positionY
      param_init(&n->params[2], 0); // positionZ
      param_init(&n->params[3], 1); // orientationX
      param_init(&n->params[4], 0); // orientationY
      param_init(&n->params[5], 0); // orientationZ
      n->panning_model = 0; // equalpower
      n->distance_model = 1; // inverse
      n->ref_distance = 1;
      n->max_distance = 10000;
      n->rolloff = 1;
      n->cone_inner = 360;
      n->cone_outer = 360;
      n->cone_gain = 0;
      break;
    case NODE_DELAY:
      param_init(&n->params[0], 0); // delayTime
      if (data != NULL) {
        DelayData *d = (DelayData *)data;
        n->delay_left = d->left;
        n->delay_right = d->right;
        n->delay_length = d->length;
        n->delay_write = 0;
        memset(d->left, 0, (size_t)d->length * sizeof(float));
        memset(d->right, 0, (size_t)d->length * sizeof(float));
        push_ptr(c, d);
      }
      break;
    case NODE_CONVOLVER:
      n->conv_buffer = -1;
      n->conv_normalize = 1;
      n->conv_scale = 1;
      break;
    case NODE_COMPRESSOR:
      param_init(&n->params[0], -24); // threshold
      param_init(&n->params[1], 30); // knee
      param_init(&n->params[2], 12); // ratio
      param_init(&n->params[3], 0.003); // attack
      param_init(&n->params[4], 0.25); // release
      n->comp_envelope = 0;
      atomic_store_explicit(&n->reduction_bits, 0, memory_order_relaxed);
      break;
    case NODE_ANALYSER:
      n->ring = (float *)data;
      atomic_store_explicit(&n->ring_write, 0, memory_order_relaxed);
      atomic_store_explicit(&n->ring_seq, 0, memory_order_relaxed);
      break;
    default:
      break;
  }
}

static void apply_cmd(AudioContext *c, Cmd *cmd) {
  switch (cmd->kind) {
    case CMD_INIT: {
      Node *n = &c->nodes[cmd->a];
      node_init(c, n, cmd->b, cmd->ptr);
      c->order_dirty = 1;
      break;
    }
    case CMD_RELEASE: {
      int id = cmd->a;
      Node *n = &c->nodes[id];
      if (!n->active) break;
      n->active = 0;
      for (int i = 0; i < AUDIO_MAX_NODES; i++) {
        Node *other = &c->nodes[i];
        if (!other->active || other->input_count == 0) continue;
        int kept = 0;
        for (int k = 0; k < other->input_count; k++) {
          if (other->inputs[k] != id) other->inputs[kept++] = other->inputs[k];
        }
        other->input_count = kept;
      }
      n->input_count = 0;
      if (n->ring != NULL) {
        push_ptr(c, n->ring);
        n->ring = NULL;
      }
      if (n->delay_left != NULL) {
        push_ptr(c, n->delay_left);
        n->delay_left = NULL;
      }
      if (n->delay_right != NULL) {
        push_ptr(c, n->delay_right);
        n->delay_right = NULL;
      }
      if (n->conv_left != NULL) {
        push_ptr(c, n->conv_left);
        n->conv_left = NULL;
      }
      if (n->conv_right != NULL) {
        push_ptr(c, n->conv_right);
        n->conv_right = NULL;
      }
      for (int i = 0; i < AUDIO_MAX_PARAMS; i++) {
        ParamEvent *e = n->params[i].head;
        while (e != NULL) {
          ParamEvent *next = e->next;
          push_trash(c, e);
          e = next;
        }
        n->params[i].head = NULL;
      }
      // A released node's slot is free once the audio thread has finished with it.
      push_free_node(c, id);
      c->order_dirty = 1;
      break;
    }
    case CMD_CONNECT: {
      Node *dst = &c->nodes[cmd->b];
      int src = cmd->a;
      if (!dst->active || !c->nodes[src].active) break;
      if (dst->input_count >= AUDIO_MAX_INPUTS) break;
      int duplicate = 0;
      for (int i = 0; i < dst->input_count; i++) if (dst->inputs[i] == src) duplicate = 1;
      if (!duplicate) dst->inputs[dst->input_count++] = src;
      c->order_dirty = 1;
      break;
    }
    case CMD_DISCONNECT: {
      int src = cmd->a, dst = cmd->b, out = cmd->c, in = cmd->d;
      for (int i = 0; i < AUDIO_MAX_NODES; i++) {
        Node *n = &c->nodes[i];
        if (!n->active || n->input_count == 0) continue;
        if (dst >= 0 && i != dst) continue;
        int kept = 0;
        for (int k = 0; k < n->input_count; k++) {
          int s = n->inputs[k];
          if (s == src && (out < 0 || out == 0) && (in < 0 || in == 0)) continue;
          n->inputs[kept++] = s;
        }
        n->input_count = kept;
      }
      c->order_dirty = 1;
      break;
    }
    case CMD_PARAM_EVENT: {
      Node *n = &c->nodes[cmd->a];
      if (!n->active || cmd->b < 0 || cmd->b >= AUDIO_MAX_PARAMS) break;
      Param *p = &n->params[cmd->b];
      ParamEvent *e = (ParamEvent *)cmd->ptr;
      if (e == NULL) break;
      double now = (double)atomic_load_explicit(&c->rendered, memory_order_acquire);
      e->kind = cmd->c;
      e->value = cmd->x;
      e->aux = cmd->z;
      e->t0 = cmd->y * c->rate;
      e->t1 = e->t0;
      param_insert(p, e, now);
      break;
    }
    case CMD_PARAM_CANCEL: {
      Node *n = &c->nodes[cmd->a];
      if (!n->active || cmd->b < 0 || cmd->b >= AUDIO_MAX_PARAMS) break;
      param_cancel(c, &n->params[cmd->b], cmd->x * c->rate, cmd->c, c->rate);
      break;
    }
    case CMD_SET_BUFFER: {
      Node *n = &c->nodes[cmd->a];
      if (!n->active) break;
      n->buffer = cmd->b;
      break;
    }
    case CMD_SOURCE_START: {
      Node *n = &c->nodes[cmd->a];
      if (!n->active) break;
      double now = (double)atomic_load_explicit(&c->rendered, memory_order_acquire);
      double when = cmd->x * c->rate;
      if (when < now) when = now;
      AudioBufferData *b = (n->buffer >= 0 && n->buffer < AUDIO_MAX_BUFFERS) ? c->buffers[n->buffer] : NULL;
      double brate = b != NULL ? b->rate : c->rate;
      n->started = 1;
      n->start_frame = when;
      n->ended = 0;
      n->has_stop = 0;
      n->pos = cmd->y * brate;
      n->has_duration = cmd->c != 0;
      n->duration_end = (cmd->y + cmd->z) * brate; // buffer frames
      break;
    }
    case CMD_SOURCE_STOP: {
      Node *n = &c->nodes[cmd->a];
      if (!n->active) break;
      double now = (double)atomic_load_explicit(&c->rendered, memory_order_acquire);
      double when = cmd->x * c->rate;
      if (when < now) when = now;
      n->has_stop = 1;
      n->stop_frame = when;
      break;
    }
    case CMD_LOOP: {
      Node *n = &c->nodes[cmd->a];
      if (!n->active) break;
      n->loop = cmd->b;
      n->loop_start = cmd->x;
      n->loop_end = cmd->y;
      break;
    }
    case CMD_OSC_TYPE: {
      Node *n = &c->nodes[cmd->a];
      if (n->active) n->osc_type = cmd->b;
      break;
    }
    case CMD_BIQUAD_TYPE: {
      Node *n = &c->nodes[cmd->a];
      if (n->active) n->biquad_type = cmd->b;
      break;
    }
    case CMD_CONV_BUFFER: {
      Node *n = &c->nodes[cmd->a];
      if (!n->active) {
        ConvolverData *d = (ConvolverData *)cmd->ptr;
        if (d != NULL) {
          push_ptr(c, d->left);
          push_ptr(c, d->right);
          push_ptr(c, d);
        }
        break;
      }
      if (n->conv_left != NULL) push_ptr(c, n->conv_left);
      if (n->conv_right != NULL) push_ptr(c, n->conv_right);
      ConvolverData *data = (ConvolverData *)cmd->ptr;
      n->conv_buffer = cmd->b;
      n->conv_normalize = cmd->c;
      n->conv_scale = 1;
      n->conv_left = NULL;
      n->conv_right = NULL;
      n->conv_length = 0;
      n->conv_write = 0;
      if (data != NULL) {
        n->conv_left = data->left;
        n->conv_right = data->right;
        n->conv_length = data->length;
        memset(data->left, 0, (size_t)data->length * sizeof(float));
        memset(data->right, 0, (size_t)data->length * sizeof(float));
        push_ptr(c, data);
      }
      AudioBufferData *ir = (cmd->b >= 0 && cmd->b < AUDIO_MAX_BUFFERS) ? c->buffers[cmd->b] : NULL;
      if (n->conv_normalize && ir != NULL && ir->frames > 0) {
        double sum = 0;
        for (int ch = 0; ch < ir->channels; ch++) {
          for (int i = 0; i < ir->frames; i++) sum += (double)ir->data[ch][i] * ir->data[ch][i];
        }
        if (sum > 1e-12) n->conv_scale = 1.0 / sqrt(sum / ((double)ir->channels * ir->frames));
      }
      break;
    }
    case CMD_PANNER_CONFIG: {
      Node *n = &c->nodes[cmd->a];
      PannerConfig *cfg = (PannerConfig *)cmd->ptr;
      if (cfg == NULL) break;
      if (n->active) {
        n->panning_model = cfg->panning_model;
        n->distance_model = cfg->distance_model;
        n->ref_distance = cfg->ref_distance;
        n->max_distance = cfg->max_distance;
        n->rolloff = cfg->rolloff;
        n->cone_inner = cfg->cone_inner;
        n->cone_outer = cfg->cone_outer;
        n->cone_gain = cfg->cone_gain;
      }
      push_ptr(c, cfg);
      break;
    }
    default:
      break;
  }
}

static void drain_commands(AudioContext *c) {
  uint32_t head = atomic_load_explicit(&c->cmd_head, memory_order_relaxed);
  uint32_t tail = atomic_load_explicit(&c->cmd_tail, memory_order_acquire);
  while (head != tail) {
    apply_cmd(c, &c->cmds[head % CMD_RING]);
    head++;
  }
  atomic_store_explicit(&c->cmd_head, head, memory_order_release);
}

static void cmd_push(AudioContext *c, Cmd *cmd) {
  if (atomic_load_explicit(&c->closed, memory_order_acquire)) return;
  if (c->offline) {
    apply_cmd(c, cmd);
    return;
  }
  uint32_t tail = atomic_load_explicit(&c->cmd_tail, memory_order_relaxed);
  for (;;) {
    uint32_t head = atomic_load_explicit(&c->cmd_head, memory_order_acquire);
    if (tail - head < CMD_RING) break;
    // The audio thread drains at every quantum, which is a few milliseconds away. Waiting here
    // is far better than dropping a graph edit.
#if defined(__linux__)
    sched_yield();
#else
    sleep_seconds(0.0002);
#endif
  }
  c->cmds[tail % CMD_RING] = *cmd;
  atomic_store_explicit(&c->cmd_tail, tail + 1, memory_order_release);
}

static int pop_free_node(AudioContext *c) {
  uint32_t head = atomic_load_explicit(&c->free_head, memory_order_relaxed);
  uint32_t tail = atomic_load_explicit(&c->free_tail, memory_order_acquire);
  if (head == tail) return -1;
  int id = c->free_ids[head % AUDIO_MAX_NODES];
  atomic_store_explicit(&c->free_head, head + 1, memory_order_release);
  return id;
}

static void push_free_node(AudioContext *c, int id) {
  uint32_t tail = atomic_load_explicit(&c->free_tail, memory_order_relaxed);
  uint32_t head = atomic_load_explicit(&c->free_head, memory_order_acquire);
  if (tail - head >= AUDIO_MAX_NODES) return;
  c->free_ids[tail % AUDIO_MAX_NODES] = id;
  atomic_store_explicit(&c->free_tail, tail + 1, memory_order_release);
}

// ---------------------------------------------------------------------------
// Rendering

static void dfs_order(AudioContext *c, int id, int *visited, int *onstack) {
  if (id < 0 || id >= AUDIO_MAX_NODES) return;
  if (visited[id] || onstack[id]) return;
  Node *n = &c->nodes[id];
  if (!n->active) return;
  onstack[id] = 1;
  for (int i = 0; i < n->input_count; i++) dfs_order(c, n->inputs[i], visited, onstack);
  onstack[id] = 0;
  visited[id] = 1;
  if (c->order_count < AUDIO_MAX_NODES) c->order[c->order_count++] = id;
}

static void build_order(AudioContext *c) {
  // Each context may render on its own thread, so the marks are this call's own.
  int visited[AUDIO_MAX_NODES];
  int onstack[AUDIO_MAX_NODES];
  memset(visited, 0, sizeof(visited));
  memset(onstack, 0, sizeof(onstack));
  c->order_count = 0;
  dfs_order(c, 0, visited, onstack);
  // Sources that aren't connected to the destination still run: an oscillator started before it
  // is connected keeps its phase, and a buffer that ends while disconnected still reports it.
  for (int i = 1; i < AUDIO_MAX_NODES; i++) {
    if (c->nodes[i].active && !visited[i]) dfs_order(c, i, visited, onstack);
  }
  c->order_dirty = 0;
}

static void mix_inputs(AudioContext *c, Node *n) {
  memset(n->in, 0, sizeof(n->in));
  for (int k = 0; k < n->input_count; k++) {
    Node *s = &c->nodes[n->inputs[k]];
    if (!s->active) continue;
    for (int i = 0; i < AUDIO_QUANTUM; i++) {
      n->in[0][i] += s->out[0][i];
      n->in[1][i] += s->out[1][i];
    }
  }
}

static float oscillator_sample(int type, double phase) {
  // Phase is in [0, 1). The shapes start at zero, as the band-limited waves browsers play do.
  switch (type) {
    case 1: // square
      return phase < 0.5 ? 1.0f : -1.0f;
    case 2: // sawtooth
      return (float)(2.0 * (phase < 0.5 ? phase : phase - 1.0));
    case 3: // triangle
      if (phase < 0.25) return (float)(4.0 * phase);
      if (phase < 0.75) return (float)(2.0 - 4.0 * phase);
      return (float)(4.0 * phase - 4.0);
    default: // sine
      return (float)sin(phase * 6.28318530717958647692);
  }
}

static void process_node(AudioContext *c, Node *n, double t0) {
  double rate = c->rate;
  switch (n->type) {
    case NODE_DESTINATION: {
      for (int i = 0; i < AUDIO_QUANTUM; i++) {
        n->out[0][i] = n->in[0][i];
        n->out[1][i] = n->in[1][i];
      }
      break;
    }
    case NODE_GAIN: {
      Param *g = &n->params[0];
      int automated = g->head != NULL || g->in_ramp || g->in_target;
      if (!automated) {
        float v = (float)g->value;
        for (int i = 0; i < AUDIO_QUANTUM; i++) {
          n->out[0][i] = n->in[0][i] * v;
          n->out[1][i] = n->in[1][i] * v;
        }
      } else {
        for (int i = 0; i < AUDIO_QUANTUM; i++) {
          float v = (float)param_at(c, g, t0 + i, rate);
          n->out[0][i] = n->in[0][i] * v;
          n->out[1][i] = n->in[1][i] * v;
        }
      }
      break;
    }
    case NODE_CONSTANT_SOURCE: {
      if (!n->started) {
        memset(n->out, 0, sizeof(n->out));
        break;
      }
      Param *off = &n->params[0];
      for (int i = 0; i < AUDIO_QUANTUM; i++) {
        double t = t0 + i;
        float v = 0;
        if (t >= n->start_frame && !(n->has_stop && t >= n->stop_frame)) {
          v = (float)param_at(c, off, t, rate);
        } else if (n->has_stop && t >= n->stop_frame && !n->ended) {
          n->ended = 1;
          push_event(c, (int)(n - c->nodes), AUDIO_EVENT_ENDED);
        }
        n->out[0][i] = v;
        n->out[1][i] = v;
      }
      break;
    }
    case NODE_OSCILLATOR: {
      if (!n->started) {
        memset(n->out, 0, sizeof(n->out));
        break;
      }
      Param *freq = &n->params[0];
      Param *detune = &n->params[1];
      double phase = n->phase;
      for (int i = 0; i < AUDIO_QUANTUM; i++) {
        double t = t0 + i;
        float v = 0;
        if (t >= n->start_frame && !(n->has_stop && t >= n->stop_frame)) {
          double f = param_at(c, freq, t, rate) * pow(2.0, param_at(c, detune, t, rate) / 1200.0);
          v = oscillator_sample(n->osc_type, phase);
          phase += f / rate;
          if (phase >= 1.0 || phase < 0.0) phase -= floor(phase);
        } else if (n->has_stop && t >= n->stop_frame && !n->ended) {
          n->ended = 1;
          push_event(c, (int)(n - c->nodes), AUDIO_EVENT_ENDED);
        }
        n->out[0][i] = v;
        n->out[1][i] = v;
      }
      n->phase = phase;
      break;
    }
    case NODE_BUFFER_SOURCE: {
      if (!n->started) {
        memset(n->out, 0, sizeof(n->out));
        break;
      }
      AudioBufferData *b = (n->buffer >= 0 && n->buffer < AUDIO_MAX_BUFFERS) ? c->buffers[n->buffer] : NULL;
      Param *prate = &n->params[0];
      Param *detune = &n->params[1];
      double pos = n->pos;
      for (int i = 0; i < AUDIO_QUANTUM; i++) {
        double t = t0 + i;
        float l = 0, r = 0;
        if (t < n->start_frame) {
          n->out[0][i] = 0;
          n->out[1][i] = 0;
          continue;
        }
        if (n->has_stop && t >= n->stop_frame) {
          if (!n->ended) {
            n->ended = 1;
            push_event(c, (int)(n - c->nodes), AUDIO_EVENT_ENDED);
          }
          n->out[0][i] = 0;
          n->out[1][i] = 0;
          continue;
        }
        if (b != NULL && b->frames > 0 && pos >= 0 && pos < (double)b->frames) {
          int ip = (int)pos;
          double frac = pos - ip;
          int next = ip + 1;
          if (next >= b->frames) next = n->loop ? 0 : b->frames - 1;
          float s0 = b->data[0][ip], s1 = b->data[0][next];
          l = (float)(s0 + (s1 - s0) * frac);
          if (b->channels > 1) {
            float r0 = b->data[1][ip], r1 = b->data[1][next];
            r = (float)(r0 + (r1 - r0) * frac);
          } else {
            r = l;
          }
        }
        double brate = b != NULL ? b->rate : rate;
        double rate_scale = param_at(c, prate, t, rate) * pow(2.0, param_at(c, detune, t, rate) / 1200.0);
        pos += rate_scale * (brate / rate);
        if (n->loop && b != NULL) {
          double ls = n->loop_start * brate;
          double le = (n->loop_end >= 0 ? n->loop_end : (double)b->frames / brate) * brate;
          if (le <= ls) le = (double)b->frames;
          if (le > (double)b->frames) le = (double)b->frames;
          if (pos >= le) {
            double span = le - ls;
            if (span > 0) pos = ls + fmod(pos - ls, span);
            else pos = ls;
          }
        }
        if (n->has_duration && pos >= n->duration_end) {
          if (!n->ended) {
            n->ended = 1;
            push_event(c, (int)(n - c->nodes), AUDIO_EVENT_ENDED);
          }
          pos = (double)(b != NULL ? b->frames : 0);
        }
        if (b != NULL && !n->loop && pos >= (double)b->frames && !n->ended) {
          n->ended = 1;
          push_event(c, (int)(n - c->nodes), AUDIO_EVENT_ENDED);
        }
        n->out[0][i] = l;
        n->out[1][i] = r;
      }
      n->pos = pos;
      break;
    }
    case NODE_BIQUAD: {
      double f0 = node_param(c, n, 0, t0, rate) * pow(2.0, node_param(c, n, 1, t0, rate) / 1200.0);
      double q = node_param(c, n, 2, t0, rate);
      double dbgain = node_param(c, n, 3, t0, rate);
      if (q <= 0) q = 0.0001;
      if (f0 < 0) f0 = 0;
      if (f0 > rate * 0.5) f0 = rate * 0.5;
      double w0 = 2.0 * 3.14159265358979323846 * f0 / rate;
      double cw = cos(w0), sw = sin(w0);
      double alpha = sw / (2.0 * q);
      double A = pow(10.0, dbgain / 40.0);
      double b0, b1, b2, a0, a1, a2;
      switch (n->biquad_type) {
        case 1: // highpass
          b0 = (1 + cw) / 2; b1 = -(1 + cw); b2 = (1 + cw) / 2;
          a0 = 1 + alpha; a1 = -2 * cw; a2 = 1 - alpha;
          break;
        case 2: // bandpass
          b0 = alpha; b1 = 0; b2 = -alpha;
          a0 = 1 + alpha; a1 = -2 * cw; a2 = 1 - alpha;
          break;
        case 3: // lowshelf
          b0 = A * ((A + 1) - (A - 1) * cw + 2 * sqrt(A) * alpha);
          b1 = 2 * A * ((A - 1) - (A + 1) * cw);
          b2 = A * ((A + 1) - (A - 1) * cw - 2 * sqrt(A) * alpha);
          a0 = (A + 1) + (A - 1) * cw + 2 * sqrt(A) * alpha;
          a1 = -2 * ((A - 1) + (A + 1) * cw);
          a2 = (A + 1) + (A - 1) * cw - 2 * sqrt(A) * alpha;
          break;
        case 4: // highshelf
          b0 = A * ((A + 1) + (A - 1) * cw + 2 * sqrt(A) * alpha);
          b1 = -2 * A * ((A - 1) + (A + 1) * cw);
          b2 = A * ((A + 1) + (A - 1) * cw - 2 * sqrt(A) * alpha);
          a0 = (A + 1) - (A - 1) * cw + 2 * sqrt(A) * alpha;
          a1 = 2 * ((A - 1) - (A + 1) * cw);
          a2 = (A + 1) - (A - 1) * cw - 2 * sqrt(A) * alpha;
          break;
        case 5: // peaking
          b0 = 1 + alpha * A; b1 = -2 * cw; b2 = 1 - alpha * A;
          a0 = 1 + alpha / A; a1 = -2 * cw; a2 = 1 - alpha / A;
          break;
        case 6: // notch
          b0 = 1; b1 = -2 * cw; b2 = 1;
          a0 = 1 + alpha; a1 = -2 * cw; a2 = 1 - alpha;
          break;
        case 7: // allpass
          b0 = 1 - alpha; b1 = -2 * cw; b2 = 1 + alpha;
          a0 = 1 + alpha; a1 = -2 * cw; a2 = 1 - alpha;
          break;
        default: // lowpass
          b0 = (1 - cw) / 2; b1 = 1 - cw; b2 = (1 - cw) / 2;
          a0 = 1 + alpha; a1 = -2 * cw; a2 = 1 - alpha;
          break;
      }
      n->b0 = b0 / a0; n->b1 = b1 / a0; n->b2 = b2 / a0;
      n->a1 = a1 / a0; n->a2 = a2 / a0;
      for (int ch = 0; ch < 2; ch++) {
        double z1 = n->z1[ch], z2 = n->z2[ch];
        for (int i = 0; i < AUDIO_QUANTUM; i++) {
          double x = n->in[ch][i];
          double y = n->b0 * x + z1;
          z1 = n->b1 * x - n->a1 * y + z2;
          z2 = n->b2 * x - n->a2 * y;
          n->out[ch][i] = (float)y;
        }
        n->z1[ch] = z1;
        n->z2[ch] = z2;
      }
      break;
    }
    case NODE_STEREO_PANNER: {
      Param *pan = &n->params[0];
      for (int i = 0; i < AUDIO_QUANTUM; i++) {
        double p = clampd(param_at(c, pan, t0 + i, rate), -1, 1);
        double l = n->in[0][i], r = n->in[1][i];
        if (p <= 0) {
          double x = p + 1;
          double gl = cos(x * 3.14159265358979323846 / 2);
          double gr = sin(x * 3.14159265358979323846 / 2);
          n->out[0][i] = (float)(l + r * gl);
          n->out[1][i] = (float)(r * gr);
        } else {
          double x = p;
          double gl = cos(x * 3.14159265358979323846 / 2);
          double gr = sin(x * 3.14159265358979323846 / 2);
          n->out[0][i] = (float)(l * gl);
          n->out[1][i] = (float)(r + l * gr);
        }
      }
      break;
    }
    case NODE_PANNER: {
      // The listener lives on the destination's unused parameters: position, then forward, then
      // up. The panner uses its own position and orientation the same way.
      Node *listener = &c->nodes[0];
      double lx = param_at(c, &listener->params[0], t0, rate);
      double ly = param_at(c, &listener->params[1], t0, rate);
      double lz = param_at(c, &listener->params[2], t0, rate);
      double fx = param_at(c, &listener->params[3], t0, rate);
      double fy = param_at(c, &listener->params[4], t0, rate);
      double fz = param_at(c, &listener->params[5], t0, rate);
      double ux = param_at(c, &listener->params[6], t0, rate);
      double uy = param_at(c, &listener->params[7], t0, rate);
      double uz = param_at(c, &listener->params[8], t0, rate);
      double flen = sqrt(fx * fx + fy * fy + fz * fz);
      if (flen < 1e-9) { fx = 0; fy = 0; fz = -1; flen = 1; }
      fx /= flen; fy /= flen; fz /= flen;
      double ulen = sqrt(ux * ux + uy * uy + uz * uz);
      if (ulen < 1e-9) { ux = 0; uy = 1; uz = 0; ulen = 1; }
      ux /= ulen; uy /= ulen; uz /= ulen;
      double rx = fy * uz - fz * uy;
      double ry = fz * ux - fx * uz;
      double rz = fx * uy - fy * ux;
      double rlen = sqrt(rx * rx + ry * ry + rz * rz);
      if (rlen < 1e-9) { rx = 1; ry = 0; rz = 0; rlen = 1; }
      rx /= rlen; ry /= rlen; rz /= rlen;

      double px = param_at(c, &n->params[0], t0, rate);
      double py = param_at(c, &n->params[1], t0, rate);
      double pz = param_at(c, &n->params[2], t0, rate);
      double ox = param_at(c, &n->params[3], t0, rate);
      double oy = param_at(c, &n->params[4], t0, rate);
      double oz = param_at(c, &n->params[5], t0, rate);
      double dx = px - lx, dy = py - ly, dz = pz - lz;
      double distance = sqrt(dx * dx + dy * dy + dz * dz);
      if (distance < 1e-6) distance = 1e-6;
      double azimuth = atan2(dx * rx + dy * ry + dz * rz, dx * fx + dy * fy + dz * fz);
      double pan = sin(azimuth);
      if (pan < -1) pan = -1;
      if (pan > 1) pan = 1;
      double gain_l = cos((pan + 1) * 3.14159265358979323846 / 4);
      double gain_r = sin((pan + 1) * 3.14159265358979323846 / 4);
      double ref = n->ref_distance > 0 ? n->ref_distance : 1;
      double maxd = n->max_distance > ref ? n->max_distance : ref;
      double distance_gain = 1;
      if (n->distance_model == 0) { // linear
        if (maxd > ref) distance_gain = 1 - n->rolloff * (distance - ref) / (maxd - ref);
      } else if (n->distance_model == 2) { // exponential
        distance_gain = pow((distance > ref ? distance : ref) / ref, -n->rolloff);
      } else { // inverse
        distance_gain = ref / (ref + n->rolloff * ((distance > ref ? distance : ref) - ref));
      }
      if (distance_gain < 0) distance_gain = 0;
      if (distance_gain > 1) distance_gain = 1;
      double cone_gain = 1;
      double olen = sqrt(ox * ox + oy * oy + oz * oz);
      if (olen > 1e-9 && n->cone_outer < 360) {
        ox /= olen; oy /= olen; oz /= olen;
        double toward = -(dx * ox + dy * oy + dz * oz) / distance;
        if (toward > 1) toward = 1;
        if (toward < -1) toward = -1;
        double angle = acos(toward) * 180.0 / 3.14159265358979323846;
        double inner = n->cone_inner * 0.5;
        double outer = n->cone_outer * 0.5;
        if (angle >= outer) cone_gain = n->cone_gain;
        else if (angle > inner && outer > inner) {
          cone_gain = n->cone_gain + (1 - n->cone_gain) * (outer - angle) / (outer - inner);
        }
      }
      float scale = (float)(distance_gain * cone_gain);
      for (int i = 0; i < AUDIO_QUANTUM; i++) {
        float mono = 0.5f * (n->in[0][i] + n->in[1][i]);
        n->out[0][i] = mono * (float)gain_l * scale;
        n->out[1][i] = mono * (float)gain_r * scale;
      }
      break;
    }
    case NODE_DELAY: {
      int length = n->delay_length;
      if (length <= 0 || n->delay_left == NULL) {
        memset(n->out, 0, sizeof(n->out));
        break;
      }
      Param *dt = &n->params[0];
      int automated = dt->head != NULL || dt->in_ramp || dt->in_target;
      int write = n->delay_write;
      for (int i = 0; i < AUDIO_QUANTUM; i++) {
        double frames = param_at(c, dt, t0 + i, rate) * rate;
        if (frames < 0) frames = 0;
        if (frames > length - 2) frames = length - 2;
        double pos = (double)write - frames;
        while (pos < 0) pos += length;
        while (pos >= length) pos -= length;
        int i0 = (int)pos;
        double frac = pos - i0;
        int i1 = i0 + 1 < length ? i0 + 1 : 0;
        float l0 = n->delay_left[i0], l1 = n->delay_left[i1];
        float r0 = n->delay_right[i0], r1 = n->delay_right[i1];
        n->out[0][i] = (float)(l0 + (l1 - l0) * frac);
        n->out[1][i] = (float)(r0 + (r1 - r0) * frac);
        n->delay_left[write] = n->in[0][i];
        n->delay_right[write] = n->in[1][i];
        write = write + 1 < length ? write + 1 : 0;
      }
      n->delay_write = write;
      (void)automated;
      break;
    }
    case NODE_COMPRESSOR: {
      double threshold = node_param(c, n, 0, t0, rate);
      double knee = node_param(c, n, 1, t0, rate);
      double ratio = node_param(c, n, 2, t0, rate);
      double attack = node_param(c, n, 3, t0, rate);
      double release = node_param(c, n, 4, t0, rate);
      if (knee < 0) knee = 0;
      if (ratio < 1) ratio = 1;
      double attack_coeff = attack > 0 ? exp(-1.0 / (attack * rate)) : 0;
      double release_coeff = release > 0 ? exp(-1.0 / (release * rate)) : 0;
      double envelope = n->comp_envelope;
      for (int i = 0; i < AUDIO_QUANTUM; i++) {
        double peak = fabs(n->in[0][i]);
        double right = fabs(n->in[1][i]);
        if (right > peak) peak = right;
        if (peak < 1e-7) peak = 1e-7;
        double db = 20 * log10(peak);
        double over = db - threshold;
        double target = 0;
        if (over > knee / 2) {
          target = over * (1.0 / ratio - 1.0);
        } else if (over > -knee / 2 && knee > 0) {
          double x = over + knee / 2;
          target = (1.0 / ratio - 1.0) * x * x / (2 * knee);
        }
        if (target < envelope) envelope = attack_coeff * envelope + (1 - attack_coeff) * target;
        else envelope = release_coeff * envelope + (1 - release_coeff) * target;
        double gain = pow(10.0, envelope / 20.0);
        n->out[0][i] = (float)(n->in[0][i] * gain);
        n->out[1][i] = (float)(n->in[1][i] * gain);
      }
      n->comp_envelope = envelope;
      {
        float f = (float)envelope;
        int bits;
        memcpy(&bits, &f, sizeof(bits));
        atomic_store_explicit(&n->reduction_bits, bits, memory_order_release);
      }
      break;
    }
    case NODE_CONVOLVER: {
      AudioBufferData *ir = (n->conv_buffer >= 0 && n->conv_buffer < AUDIO_MAX_BUFFERS)
        ? c->buffers[n->conv_buffer] : NULL;
      int length = n->conv_length;
      if (ir == NULL || ir->frames <= 0 || length <= 0 || n->conv_left == NULL) {
        memset(n->out, 0, sizeof(n->out));
        break;
      }
      int taps = ir->frames;
      if (taps > length) taps = length;
      int write = n->conv_write;
      double scale = n->conv_scale;
      for (int i = 0; i < AUDIO_QUANTUM; i++) {
        n->conv_left[write] = n->in[0][i];
        n->conv_right[write] = n->in[1][i];
        double left = 0, right = 0;
        for (int k = 0; k < taps; k++) {
          int idx = write - k;
          if (idx < 0) idx += length;
          float impulse_left = ir->data[0][k];
          left += impulse_left * n->conv_left[idx];
          if (ir->channels > 1) right += ir->data[1][k] * n->conv_right[idx];
          else right += impulse_left * n->conv_right[idx];
        }
        n->out[0][i] = (float)(left * scale);
        n->out[1][i] = (float)(right * scale);
        write = write + 1 < length ? write + 1 : 0;
      }
      n->conv_write = write;
      break;
    }
    case NODE_ANALYSER: {
      for (int i = 0; i < AUDIO_QUANTUM; i++) {
        n->out[0][i] = n->in[0][i];
        n->out[1][i] = n->in[1][i];
      }
      if (n->ring != NULL) {
        uint32_t seq = atomic_load_explicit(&n->ring_seq, memory_order_relaxed);
        atomic_store_explicit(&n->ring_seq, seq + 1, memory_order_release);
        uint32_t w = atomic_load_explicit(&n->ring_write, memory_order_relaxed);
        for (int i = 0; i < AUDIO_QUANTUM; i++) {
          n->ring[w] = 0.5f * (n->in[0][i] + n->in[1][i]);
          w = (w + 1) % AUDIO_ANALYSER_RING;
        }
        atomic_store_explicit(&n->ring_write, w, memory_order_release);
        atomic_store_explicit(&n->ring_seq, seq + 2, memory_order_release);
      }
      break;
    }
    default:
      memset(n->out, 0, sizeof(n->out));
      break;
  }
}

static void render_quantum(AudioContext *c) {
  drain_commands(c);
  if (c->order_dirty) build_order(c);
  c->timestamp = atomic_load_explicit(&c->rendered, memory_order_acquire);
  for (int k = 0; k < c->order_count; k++) {
    int id = c->order[k];
    Node *n = &c->nodes[id];
    if (!n->active) continue;
    mix_inputs(c, n);
    process_node(c, n, (double)c->timestamp);
  }
  // The destination is node 0 whether or not a graph connects to it.
  Node *dst = &c->nodes[0];
  for (int i = 0; i < AUDIO_QUANTUM; i++) {
    c->ql[i] = dst->active ? dst->out[0][i] : 0;
    c->qr[i] = dst->active ? dst->out[1][i] : 0;
  }
  c->qpos = 0;
  c->qlen = AUDIO_QUANTUM;
  // A `.value` read sees the parameter as the quantum left it.
  for (int k = 0; k < c->order_count; k++) {
    Node *n = &c->nodes[c->order[k]];
    if (!n->active) continue;
    for (int p = 0; p < AUDIO_MAX_PARAMS; p++) {
      float f = (float)n->params[p].value;
      int bits;
      memcpy(&bits, &f, sizeof(bits));
      atomic_store_explicit(&n->params[p].current_bits, bits, memory_order_release);
    }
  }
}

static void pull_frame(AudioContext *c, float *l, float *r) {
  if (c->qpos >= c->qlen) render_quantum(c);
  *l = c->ql[c->qpos];
  *r = c->qr[c->qpos];
  c->qpos++;
  // The clock counts delivered frames, not rendered quanta: an offline render stops exactly at
  // its length, and a suspended context stops where it was.
  atomic_fetch_add_explicit(&c->rendered, 1, memory_order_acq_rel);
}

/** Fills `frames` interleaved stereo frames at the device's rate. */
static void render_device_frames(AudioContext *c, float *out, int frames) {
  if (!atomic_load_explicit(&c->running, memory_order_acquire) ||
      atomic_load_explicit(&c->closed, memory_order_acquire)) {
    memset(out, 0, (size_t)frames * 2 * sizeof(float));
    return;
  }
  if (c->device_rate <= 0) c->device_rate = c->rate;
  double ratio = c->rate / c->device_rate;
  for (int i = 0; i < frames; i++) {
    if (ratio == 1.0) {
      float l = 0, r = 0;
      pull_frame(c, &l, &r);
      out[i * 2] = l;
      out[i * 2 + 1] = r;
    } else {
      if (!c->rs_started) {
        pull_frame(c, &c->rs_prev_l, &c->rs_prev_r);
        pull_frame(c, &c->rs_next_l, &c->rs_next_r);
        c->rs_phase = 0;
        c->rs_started = 1;
      }
      while (c->rs_phase >= 1.0) {
        c->rs_prev_l = c->rs_next_l;
        c->rs_prev_r = c->rs_next_r;
        pull_frame(c, &c->rs_next_l, &c->rs_next_r);
        c->rs_phase -= 1.0;
      }
      double u = c->rs_phase;
      out[i * 2] = (float)(c->rs_prev_l + (c->rs_next_l - c->rs_prev_l) * u);
      out[i * 2 + 1] = (float)(c->rs_prev_r + (c->rs_next_r - c->rs_prev_r) * u);
      c->rs_phase += ratio;
    }
  }
}

// A context without an output device still needs its clock: a silent thread renders at the
// device rate so currentTime advances, events fire, and source commands are drained.
static void *null_audio_thread(void *arg) {
  AudioContext *c = (AudioContext *)arg;
  const int chunk = 512;
  float buffer[512 * 2];
  double rate = c->device_rate > 0 ? c->device_rate : c->rate;
  double seconds = (double)chunk / rate;
  while (!atomic_load_explicit(&c->thread_stop, memory_order_acquire)) {
    render_device_frames(c, buffer, chunk);
    sleep_seconds(seconds);
  }
  return NULL;
}

static int start_null_thread(AudioContext *c) {
  if (c->thread_live) return 0;
  c->thread_live = 1;
  atomic_store_explicit(&c->thread_stop, 0, memory_order_release);
  if (pthread_create(&c->thread, NULL, null_audio_thread, c) != 0) {
    c->thread_live = 0;
    return -1;
  }
  pthread_detach(c->thread);
  return 0;
}

// ---------------------------------------------------------------------------
// Platform output

#if defined(__APPLE__)

static OSStatus au_callback(void *ref, AudioUnitRenderActionFlags *flags, const AudioTimeStamp *ts,
                            UInt32 bus, UInt32 frames, AudioBufferList *io) {
  (void)flags; (void)ts; (void)bus;
  AudioContext *c = (AudioContext *)ref;
  if (io->mNumberBuffers == 0) return noErr;
  float *l = (float *)io->mBuffers[0].mData;
  float *r = io->mNumberBuffers > 1 ? (float *)io->mBuffers[1].mData : NULL;
  static float tmp[2048 * 2];
  UInt32 done = 0;
  while (done < frames) {
    UInt32 n = frames - done;
    if (n > 2048) n = 2048;
    render_device_frames(c, tmp, (int)n);
    for (UInt32 i = 0; i < n * 2; i++) {
      if (tmp[i] > 1.0f) tmp[i] = 1.0f;
      else if (tmp[i] < -1.0f) tmp[i] = -1.0f;
    }
    for (UInt32 i = 0; i < n; i++) l[done + i] = tmp[i * 2];
    if (r != NULL) {
      for (UInt32 i = 0; i < n; i++) r[done + i] = tmp[i * 2 + 1];
    }
    done += n;
  }
  return noErr;
}

static int platform_open(AudioContext *c) {
  AudioComponentDescription desc;
  memset(&desc, 0, sizeof(desc));
  desc.componentType = kAudioUnitType_Output;
  desc.componentSubType = kAudioUnitSubType_DefaultOutput;
  desc.componentManufacturer = kAudioUnitManufacturer_Apple;
  AudioComponent comp = AudioComponentFindNext(NULL, &desc);
  if (comp == NULL) return -1;
  AudioUnit unit = NULL;
  if (AudioComponentInstanceNew(comp, &unit) != noErr || unit == NULL) return -1;

  double device_rate = 48000;
  AudioObjectPropertyAddress addr;
  addr.mSelector = kAudioHardwarePropertyDefaultOutputDevice;
  addr.mScope = kAudioObjectPropertyScopeGlobal;
  addr.mElement = kAudioObjectPropertyElementMain;
  AudioDeviceID dev = 0;
  UInt32 size = sizeof(dev);
  if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &addr, 0, NULL, &size, &dev) == noErr && dev != 0) {
    double nominal = 0;
    addr.mSelector = kAudioDevicePropertyNominalSampleRate;
    size = sizeof(nominal);
    if (AudioObjectGetPropertyData(dev, &addr, 0, NULL, &size, &nominal) == noErr && nominal > 0) {
      device_rate = nominal;
    }
  }
  c->device_rate = device_rate;

  AudioStreamBasicDescription fmt;
  memset(&fmt, 0, sizeof(fmt));
  fmt.mSampleRate = device_rate;
  fmt.mFormatID = kAudioFormatLinearPCM;
  fmt.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved;
  fmt.mChannelsPerFrame = 2;
  fmt.mBitsPerChannel = 32;
  fmt.mFramesPerPacket = 1;
  fmt.mBytesPerFrame = 4;
  fmt.mBytesPerPacket = 4;
  AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &fmt, sizeof(fmt));

  UInt32 max_frames = 4096;
  AudioUnitSetProperty(unit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0,
                       &max_frames, sizeof(max_frames));

  AURenderCallbackStruct cb;
  cb.inputProc = au_callback;
  cb.inputProcRefCon = c;
  AudioUnitSetProperty(unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0,
                       &cb, sizeof(cb));
  if (AudioUnitInitialize(unit) != noErr) {
    AudioComponentInstanceDispose(unit);
    return -1;
  }
  if (AudioOutputUnitStart(unit) != noErr) {
    AudioUnitUninitialize(unit);
    AudioComponentInstanceDispose(unit);
    return -1;
  }
  c->platform = unit;
  c->device_rate = device_rate;
  return 0;
}

static void platform_close(AudioContext *c) {
  if (c->platform != NULL) {
    AudioUnit unit = (AudioUnit)c->platform;
    AudioOutputUnitStop(unit);
    AudioUnitUninitialize(unit);
    AudioComponentInstanceDispose(unit);
    c->platform = NULL;
  }
  if (c->thread_live) {
    atomic_store_explicit(&c->thread_stop, 1, memory_order_release);
    sleep_seconds(0.06);
    c->thread_live = 0;
  }
}

#elif defined(__linux__)

#if defined(__linux__)
// A machine without a sound card is normal in a headless run: ALSA would print a page of
// complaints while the engine falls back to its silent clock. Its errors aren't the app's.
static void alsa_quiet(const char *file, int line, const char *function, int errcode, const char *format, ...) {
  (void)file; (void)line; (void)function; (void)errcode; (void)format;
}
#endif

static void *linux_audio_thread(void *arg) {
  AudioContext *c = (AudioContext *)arg;
  snd_lib_error_set_handler(alsa_quiet);
  snd_pcm_t *pcm = NULL;
  int use_alsa = 1;
  snd_pcm_hw_params_t *params = NULL;
  unsigned int rate = (unsigned int)(c->device_rate > 0 ? c->device_rate : 48000);
  c->device_rate = rate;

  if (snd_pcm_open(&pcm, "default", SND_PCM_STREAM_PLAYBACK, 0) < 0) {
    use_alsa = 0;
    pcm = NULL;
  }
  if (use_alsa) {
    snd_pcm_hw_params_alloca(&params);
    if (snd_pcm_hw_params_any(pcm, params) < 0 ||
        snd_pcm_hw_params_set_access(pcm, params, SND_PCM_ACCESS_RW_INTERLEAVED) < 0 ||
        snd_pcm_hw_params_set_format(pcm, params, SND_PCM_FORMAT_FLOAT_LE) < 0 ||
        snd_pcm_hw_params_set_channels(pcm, params, 2) < 0 ||
        snd_pcm_hw_params_set_rate_near(pcm, params, &rate, 0) < 0 ||
        snd_pcm_hw_params(pcm, params) < 0) {
      snd_pcm_close(pcm);
      pcm = NULL;
      use_alsa = 0;
    } else {
      c->device_rate = rate;
      snd_pcm_prepare(pcm);
    }
  }

  const int chunk = 1024;
  float *buffer = (float *)malloc((size_t)chunk * 2 * sizeof(float));
  double chunk_seconds = (double)chunk / (double)c->device_rate;
  while (!atomic_load_explicit(&c->thread_stop, memory_order_acquire)) {
    render_device_frames(c, buffer, chunk);
    if (use_alsa && pcm != NULL) {
      snd_pcm_sframes_t written = snd_pcm_writei(pcm, buffer, chunk);
      if (written < 0) {
        snd_pcm_prepare(pcm);
        continue;
      }
    } else {
      sleep_seconds(chunk_seconds);
    }
  }
  if (pcm != NULL) snd_pcm_close(pcm);
  free(buffer);
  return NULL;
}

static int platform_open(AudioContext *c) {
  c->thread_live = 1;
  atomic_store_explicit(&c->thread_stop, 0, memory_order_release);
  if (pthread_create(&c->thread, NULL, linux_audio_thread, c) != 0) {
    c->thread_live = 0;
    return -1;
  }
  pthread_detach(c->thread);
  return 0;
}

static void platform_close(AudioContext *c) {
  if (!c->thread_live) return;
  atomic_store_explicit(&c->thread_stop, 1, memory_order_release);
  struct timespec ts;
  ts.tv_sec = 0;
  ts.tv_nsec = 60000000; // 60 ms, more than the audio thread's longest write or sleep
  nanosleep(&ts, NULL);
  c->thread_live = 0;
}

#else

static int platform_open(AudioContext *c) { (void)c; return -1; }
static void platform_close(AudioContext *c) { (void)c; }

#endif

// ---------------------------------------------------------------------------
// Context lifecycle

static AudioContext *context_new(int offline, double rate) {
  AudioContext *c = (AudioContext *)calloc(1, sizeof(AudioContext));
  if (c == NULL) return NULL;
  c->offline = offline;
  c->channels = 2;
  c->rate = rate > 0 ? rate : 48000;
  c->device_rate = c->rate;
  c->qpos = 0;
  c->qlen = 0;
  atomic_store_explicit(&c->running, offline ? 1 : 0, memory_order_relaxed);
  for (int i = 1; i < AUDIO_MAX_NODES; i++) c->free_ids[i - 1] = i;
  atomic_store_explicit(&c->free_tail, AUDIO_MAX_NODES - 1, memory_order_relaxed);
  node_init(c, &c->nodes[0], NODE_DESTINATION, NULL);
  build_order(c);
  return c;
}

int32_t host_audio_context_create(double rate, int32_t offline) {
  AudioContext *c = context_new(offline, rate);
  if (c == NULL) return -1;
  if (!offline) {
    if (platform_open(c) == 0) {
      // With no rate asked for, the device picks it, as a browser's context does.
      if (rate <= 0) c->rate = c->device_rate;
    } else {
      // No device: the engine still runs, on a silent clock the runtime can suspend and close.
      c->device_rate = c->rate;
      start_null_thread(c);
    }
  }
  pthread_mutex_lock(&g_contexts_lock);
  int id = 0;
  for (int i = 1; i < MAX_CONTEXTS; i++) {
    if (g_contexts[i] == NULL) {
      id = i;
      g_contexts[i] = c;
      break;
    }
  }
  pthread_mutex_unlock(&g_contexts_lock);
  if (id == 0) {
    platform_close(c);
    free(c);
    return -1;
  }
  c->id = id;
  return id;
}

AudioContext *audio_context_get(int32_t id) {
  if (id <= 0 || id >= MAX_CONTEXTS) return NULL;
  AudioContext *c = g_contexts[id];
  if (c == NULL || atomic_load_explicit(&c->closed, memory_order_acquire)) return NULL;
  return c;
}

double audio_context_rate(AudioContext *c) { return c != NULL ? c->rate : 0; }

double host_audio_context_rate(int32_t id) {
  AudioContext *c = audio_context_get(id);
  return c != NULL ? c->rate : 0;
}

double host_audio_context_device_rate(int32_t id) {
  AudioContext *c = audio_context_get(id);
  return c != NULL ? c->device_rate : 0;
}

double host_audio_context_rendered(int32_t id) {
  AudioContext *c = audio_context_get(id);
  if (c == NULL) return 0;
  return (double)atomic_load_explicit(&c->rendered, memory_order_acquire);
}

void host_audio_context_resume(int32_t id) {
  AudioContext *c = audio_context_get(id);
  if (c == NULL) return;
  atomic_store_explicit(&c->running, 1, memory_order_release);
}

void host_audio_context_suspend(int32_t id) {
  AudioContext *c = audio_context_get(id);
  if (c == NULL) return;
  atomic_store_explicit(&c->running, 0, memory_order_release);
}

void host_audio_context_collect(int32_t id) {
  AudioContext *c = audio_context_get(id);
  if (c != NULL) collect(c);
}

void host_audio_context_close(int32_t id) {
  if (id <= 0 || id >= MAX_CONTEXTS) return;
  pthread_mutex_lock(&g_contexts_lock);
  AudioContext *c = g_contexts[id];
  g_contexts[id] = NULL;
  pthread_mutex_unlock(&g_contexts_lock);
  if (c == NULL) return;
  atomic_store_explicit(&c->closed, 1, memory_order_release);
  atomic_store_explicit(&c->running, 0, memory_order_release);
  platform_close(c);
  collect(c);
  for (int i = 0; i < AUDIO_MAX_BUFFERS; i++) {
    if (c->buffers[i] != NULL) audio_buffer_free(c->buffers[i]);
  }
  for (int i = 0; i < AUDIO_MAX_NODES; i++) {
    if (c->nodes[i].ring != NULL) free(c->nodes[i].ring);
    for (int p = 0; p < AUDIO_MAX_PARAMS; p++) {
      ParamEvent *e = c->nodes[i].params[p].head;
      while (e != NULL) {
        ParamEvent *next = e->next;
        free(e);
        e = next;
      }
    }
  }
  free(c);
}

int32_t host_audio_node_create(int32_t id, int32_t type, double extra) {
  AudioContext *c = audio_context_get(id);
  if (c == NULL) return -1;
  int node = pop_free_node(c);
  if (node < 0) return -1;
  void *data = NULL;
  if (type == NODE_ANALYSER) {
    data = calloc(AUDIO_ANALYSER_RING, sizeof(float));
  } else if (type == NODE_DELAY) {
    double seconds = extra > 0 ? extra : 1;
    if (seconds > 60) seconds = 60;
    int length = (int)(seconds * c->rate) + AUDIO_QUANTUM + 2;
    DelayData *d = (DelayData *)calloc(1, sizeof(DelayData));
    if (d != NULL) {
      d->left = (float *)calloc((size_t)length, sizeof(float));
      d->right = (float *)calloc((size_t)length, sizeof(float));
      d->length = length;
      if (d->left == NULL || d->right == NULL) {
        free(d->left);
        free(d->right);
        free(d);
        d = NULL;
      }
    }
    data = d;
  }
  if ((type == NODE_ANALYSER || type == NODE_DELAY) && data == NULL) {
    push_free_node(c, node);
    return -1;
  }
  memset(&c->nodes[node], 0, sizeof(Node));
  Cmd cmd;
  memset(&cmd, 0, sizeof(cmd));
  cmd.kind = CMD_INIT;
  cmd.a = node;
  cmd.b = type;
  cmd.ptr = data;
  cmd_push(c, &cmd);
  return node;
}

void host_audio_panner_config(int32_t id, int32_t node, int32_t panning_model,
                              int32_t distance_model, double ref_distance, double max_distance,
                              double rolloff, double cone_inner, double cone_outer, double cone_gain) {
  AudioContext *c = audio_context_get(id);
  if (c == NULL || node <= 0 || node >= AUDIO_MAX_NODES) return;
  PannerConfig *cfg = (PannerConfig *)malloc(sizeof(PannerConfig));
  if (cfg == NULL) return;
  cfg->panning_model = panning_model;
  cfg->distance_model = distance_model;
  cfg->ref_distance = ref_distance;
  cfg->max_distance = max_distance;
  cfg->rolloff = rolloff;
  cfg->cone_inner = cone_inner;
  cfg->cone_outer = cone_outer;
  cfg->cone_gain = cone_gain;
  Cmd cmd;
  memset(&cmd, 0, sizeof(cmd));
  cmd.kind = CMD_PANNER_CONFIG;
  cmd.a = node;
  cmd.ptr = cfg;
  cmd_push(c, &cmd);
}

void host_audio_convolver_buffer(int32_t id, int32_t node, int32_t buffer, int32_t normalize) {
  AudioContext *c = audio_context_get(id);
  if (c == NULL || node <= 0 || node >= AUDIO_MAX_NODES) return;
  AudioBufferData *ir = (buffer >= 0 && buffer < AUDIO_MAX_BUFFERS) ? c->buffers[buffer] : NULL;
  ConvolverData *data = NULL;
  if (ir != NULL && ir->frames > 0) {
    data = (ConvolverData *)calloc(1, sizeof(ConvolverData));
    if (data != NULL) {
      data->length = ir->frames;
      data->left = (float *)calloc((size_t)data->length, sizeof(float));
      data->right = (float *)calloc((size_t)data->length, sizeof(float));
      if (data->left == NULL || data->right == NULL) {
        free(data->left);
        free(data->right);
        free(data);
        data = NULL;
      }
    }
  }
  Cmd cmd;
  memset(&cmd, 0, sizeof(cmd));
  cmd.kind = CMD_CONV_BUFFER;
  cmd.a = node;
  cmd.b = buffer;
  cmd.c = normalize ? 1 : 0;
  cmd.ptr = data;
  cmd_push(c, &cmd);
}

double host_audio_compressor_reduction(int32_t id, int32_t node) {
  AudioContext *c = audio_context_get(id);
  if (c == NULL || node <= 0 || node >= AUDIO_MAX_NODES) return 0;
  int bits = atomic_load_explicit(&c->nodes[node].reduction_bits, memory_order_acquire);
  float f;
  memcpy(&f, &bits, sizeof(f));
  return f;
}

void host_audio_node_release(int32_t id, int32_t node) {
  AudioContext *c = audio_context_get(id);
  if (c == NULL || node <= 0) return;
  Cmd cmd;
  memset(&cmd, 0, sizeof(cmd));
  cmd.kind = CMD_RELEASE;
  cmd.a = node;
  cmd_push(c, &cmd);
}

void host_audio_connect(int32_t id, int32_t src, int32_t dst, int32_t out, int32_t in) {
  AudioContext *c = audio_context_get(id);
  if (c == NULL) return;
  Cmd cmd;
  memset(&cmd, 0, sizeof(cmd));
  cmd.kind = CMD_CONNECT;
  cmd.a = src;
  cmd.b = dst;
  cmd.c = out;
  cmd.d = in;
  cmd_push(c, &cmd);
}

void host_audio_disconnect(int32_t id, int32_t src, int32_t dst, int32_t out, int32_t in) {
  AudioContext *c = audio_context_get(id);
  if (c == NULL) return;
  Cmd cmd;
  memset(&cmd, 0, sizeof(cmd));
  cmd.kind = CMD_DISCONNECT;
  cmd.a = src;
  cmd.b = dst;
  cmd.c = out;
  cmd.d = in;
  cmd_push(c, &cmd);
}

void host_audio_param_set(int32_t id, int32_t node, int32_t param, double value) {
  AudioContext *c = audio_context_get(id);
  if (c == NULL) return;
  if (node < 0 || node >= AUDIO_MAX_NODES || param < 0 || param >= AUDIO_MAX_PARAMS) return;
  float f = (float)value;
  int bits;
  memcpy(&bits, &f, sizeof(bits));
  atomic_store_explicit(&c->nodes[node].params[param].current_bits, bits, memory_order_release);
  // The event is allocated here, on the script thread: the audio thread only links it in.
  ParamEvent *e = (ParamEvent *)malloc(sizeof(ParamEvent));
  if (e == NULL) return;
  memset(e, 0, sizeof(*e));
  Cmd cmd;
  memset(&cmd, 0, sizeof(cmd));
  cmd.kind = CMD_PARAM_EVENT;
  cmd.a = node;
  cmd.b = param;
  cmd.c = EV_SET_VALUE;
  cmd.x = value;
  cmd.y = c->rate > 0 ? (double)atomic_load_explicit(&c->rendered, memory_order_acquire) / c->rate : 0;
  cmd.ptr = e;
  cmd_push(c, &cmd);
}

double host_audio_param_value(int32_t id, int32_t node, int32_t param) {
  AudioContext *c = audio_context_get(id);
  if (c == NULL) return 0;
  if (node < 0 || node >= AUDIO_MAX_NODES || param < 0 || param >= AUDIO_MAX_PARAMS) return 0;
  int bits = atomic_load_explicit(&c->nodes[node].params[param].current_bits, memory_order_acquire);
  float f;
  memcpy(&f, &bits, sizeof(f));
  return f;
}

void host_audio_param_event(int32_t id, int32_t node, int32_t param, int32_t kind,
                            double end_time, double value, double aux) {
  AudioContext *c = audio_context_get(id);
  if (c == NULL) return;
  if (node < 0 || node >= AUDIO_MAX_NODES || param < 0 || param >= AUDIO_MAX_PARAMS) return;
  ParamEvent *e = (ParamEvent *)malloc(sizeof(ParamEvent));
  if (e == NULL) return;
  memset(e, 0, sizeof(*e));
  Cmd cmd;
  memset(&cmd, 0, sizeof(cmd));
  cmd.kind = CMD_PARAM_EVENT;
  cmd.a = node;
  cmd.b = param;
  cmd.c = kind;
  cmd.x = value;
  cmd.y = end_time;
  cmd.z = aux;
  cmd.ptr = e;
  cmd_push(c, &cmd);
}

void host_audio_param_cancel(int32_t id, int32_t node, int32_t param, double time, int32_t hold) {
  AudioContext *c = audio_context_get(id);
  if (c == NULL) return;
  Cmd cmd;
  memset(&cmd, 0, sizeof(cmd));
  cmd.kind = CMD_PARAM_CANCEL;
  cmd.a = node;
  cmd.b = param;
  cmd.x = time;
  cmd.c = hold;
  cmd_push(c, &cmd);
}

void host_audio_source_buffer(int32_t id, int32_t node, int32_t buffer) {
  AudioContext *c = audio_context_get(id);
  if (c == NULL) return;
  Cmd cmd;
  memset(&cmd, 0, sizeof(cmd));
  cmd.kind = CMD_SET_BUFFER;
  cmd.a = node;
  cmd.b = buffer;
  cmd_push(c, &cmd);
}

void host_audio_source_start(int32_t id, int32_t node, double when, double offset,
                             double duration, int32_t has_duration) {
  AudioContext *c = audio_context_get(id);
  if (c == NULL) return;
  Cmd cmd;
  memset(&cmd, 0, sizeof(cmd));
  cmd.kind = CMD_SOURCE_START;
  cmd.a = node;
  cmd.x = when;
  cmd.y = offset;
  cmd.z = duration;
  cmd.c = has_duration;
  cmd_push(c, &cmd);
}

void host_audio_source_stop(int32_t id, int32_t node, double when) {
  AudioContext *c = audio_context_get(id);
  if (c == NULL) return;
  Cmd cmd;
  memset(&cmd, 0, sizeof(cmd));
  cmd.kind = CMD_SOURCE_STOP;
  cmd.a = node;
  cmd.x = when;
  cmd_push(c, &cmd);
}

void host_audio_source_loop(int32_t id, int32_t node, int32_t loop, double start, double end) {
  AudioContext *c = audio_context_get(id);
  if (c == NULL) return;
  Cmd cmd;
  memset(&cmd, 0, sizeof(cmd));
  cmd.kind = CMD_LOOP;
  cmd.a = node;
  cmd.b = loop;
  cmd.x = start;
  cmd.y = end;
  cmd_push(c, &cmd);
}

void host_audio_oscillator_type(int32_t id, int32_t node, int32_t type) {
  AudioContext *c = audio_context_get(id);
  if (c == NULL) return;
  Cmd cmd;
  memset(&cmd, 0, sizeof(cmd));
  cmd.kind = CMD_OSC_TYPE;
  cmd.a = node;
  cmd.b = type;
  cmd_push(c, &cmd);
}

void host_audio_biquad_type(int32_t id, int32_t node, int32_t type) {
  AudioContext *c = audio_context_get(id);
  if (c == NULL) return;
  Cmd cmd;
  memset(&cmd, 0, sizeof(cmd));
  cmd.kind = CMD_BIQUAD_TYPE;
  cmd.a = node;
  cmd.b = type;
  cmd_push(c, &cmd);
}

int32_t audio_buffer_new(AudioContext *c, int channels, int frames, double rate) {
  if (c == NULL || channels < 1 || channels > 2 || frames < 0) return -1;
  int id = -1;
  for (int i = 1; i < AUDIO_MAX_BUFFERS; i++) {
    if (c->buffers[i] == NULL) { id = i; break; }
  }
  if (id < 0) return -1;
  AudioBufferData *b = (AudioBufferData *)calloc(1, sizeof(AudioBufferData));
  if (b == NULL) return -1;
  b->channels = channels;
  b->frames = frames;
  b->rate = rate > 0 ? rate : c->rate;
  for (int ch = 0; ch < channels; ch++) {
    b->data[ch] = (float *)calloc((size_t)frames, sizeof(float));
    if (b->data[ch] == NULL) {
      audio_buffer_free(b);
      return -1;
    }
  }
  c->buffers[id] = b;
  return id;
}

AudioBufferData *audio_buffer_get(AudioContext *c, int32_t id) {
  if (c == NULL || id <= 0 || id >= AUDIO_MAX_BUFFERS) return NULL;
  return c->buffers[id];
}

void audio_buffer_free(AudioBufferData *b) {
  if (b == NULL) return;
  for (int ch = 0; ch < 2; ch++) free(b->data[ch]);
  free(b);
}

int32_t host_audio_buffer_create(int32_t id, int32_t channels, int32_t frames, double rate) {
  AudioContext *c = audio_context_get(id);
  return audio_buffer_new(c, channels, frames, rate);
}

void host_audio_buffer_write(int32_t id, int32_t buffer, int32_t channel,
                             const uint8_t *bytes, size_t len) {
  AudioContext *c = audio_context_get(id);
  AudioBufferData *b = audio_buffer_get(c, buffer);
  if (b == NULL || channel < 0 || channel >= b->channels) return;
  size_t need = (size_t)b->frames * sizeof(float);
  if (len < need) return;
  memcpy(b->data[channel], bytes, need);
}

void host_audio_buffer_read(int32_t id, int32_t buffer, int32_t channel,
                            void (*cb)(const uint8_t *, size_t)) {
  AudioContext *c = audio_context_get(id);
  AudioBufferData *b = audio_buffer_get(c, buffer);
  if (b == NULL || channel < 0 || channel >= b->channels) {
    cb(NULL, 0);
    return;
  }
  cb((const uint8_t *)b->data[channel], (size_t)b->frames * sizeof(float));
}

int32_t host_audio_buffer_channels(int32_t id, int32_t buffer) {
  AudioBufferData *b = audio_buffer_get(audio_context_get(id), buffer);
  return b != NULL ? b->channels : 0;
}

int32_t host_audio_buffer_frames(int32_t id, int32_t buffer) {
  AudioBufferData *b = audio_buffer_get(audio_context_get(id), buffer);
  return b != NULL ? b->frames : 0;
}

double host_audio_buffer_rate(int32_t id, int32_t buffer) {
  AudioBufferData *b = audio_buffer_get(audio_context_get(id), buffer);
  return b != NULL ? b->rate : 0;
}

void host_audio_buffer_release(int32_t id, int32_t buffer) {
  AudioContext *c = audio_context_get(id);
  if (c == NULL || buffer <= 0 || buffer >= AUDIO_MAX_BUFFERS) return;
  if (c->buffers[buffer] != NULL) {
    audio_buffer_free(c->buffers[buffer]);
    c->buffers[buffer] = NULL;
  }
}

void host_audio_offline_render(int32_t id, int32_t frames, void (*cb)(const uint8_t *, size_t)) {
  AudioContext *c = audio_context_get(id);
  if (c == NULL || frames <= 0) return;
  float *out = (float *)malloc((size_t)frames * 2 * sizeof(float));
  if (out == NULL) return;
  for (int i = 0; i < frames; i++) {
    float l = 0, r = 0;
    pull_frame(c, &l, &r);
    out[i * 2] = l;
    out[i * 2 + 1] = r;
  }
  cb((const uint8_t *)out, (size_t)frames * 2 * sizeof(float));
  free(out);
  collect(c);
}

void host_audio_events(int32_t id, void (*cb)(const uint8_t *, size_t)) {
  AudioContext *c = audio_context_get(id);
  if (c == NULL) {
    cb(NULL, 0);
    return;
  }
  int32_t records[EVENT_RING * 2];
  int n = 0;
  uint32_t head = atomic_load_explicit(&c->ev_head, memory_order_relaxed);
  uint32_t tail = atomic_load_explicit(&c->ev_tail, memory_order_acquire);
  while (head != tail && n < EVENT_RING * 2) {
    AudioEvent *e = &c->events[head % EVENT_RING];
    records[n++] = e->node;
    records[n++] = e->kind;
    head++;
  }
  atomic_store_explicit(&c->ev_head, head, memory_order_release);
  cb((const uint8_t *)records, (size_t)n * sizeof(int32_t));
}

void host_audio_analyser_data(int32_t id, int32_t node, int32_t count,
                              void (*cb)(const uint8_t *, size_t)) {
  AudioContext *c = audio_context_get(id);
  if (c == NULL || node <= 0 || node >= AUDIO_MAX_NODES) {
    cb(NULL, 0);
    return;
  }
  Node *n = &c->nodes[node];
  if (!n->active || n->type != NODE_ANALYSER || n->ring == NULL || count <= 0) {
    cb(NULL, 0);
    return;
  }
  if (count > AUDIO_ANALYSER_RING) count = AUDIO_ANALYSER_RING;
  float *tmp = (float *)malloc((size_t)count * sizeof(float));
  if (tmp == NULL) { cb(NULL, 0); return; }
  for (int attempt = 0; attempt < 16; attempt++) {
    uint32_t seq1 = atomic_load_explicit(&n->ring_seq, memory_order_acquire);
    if (seq1 & 1) continue;
    uint32_t w = atomic_load_explicit(&n->ring_write, memory_order_acquire);
    for (int i = 0; i < count; i++) {
      int index = (int)((w + AUDIO_ANALYSER_RING - count + i) % AUDIO_ANALYSER_RING);
      tmp[i] = n->ring[index];
    }
    uint32_t seq2 = atomic_load_explicit(&n->ring_seq, memory_order_acquire);
    if (seq1 == seq2) break;
  }
  cb((const uint8_t *)tmp, (size_t)count * sizeof(float));
  free(tmp);
}
