#include "homi_llm.h"
#include <algorithm>
#include <atomic>
#include <chrono>
#include <cstring>
#include <memory>
#include <mutex>
#include <string>
#include <vector>
#ifndef HOMI_LLAMA_TRIAL
#define HOMI_LLAMA_TRIAL 0
#endif
#if HOMI_LLAMA_TRIAL
#if defined(__APPLE__) && !defined(HOMI_LLAMA_HOST)
#include <llama/llama.h>
#else
#include "llama.h"
#endif
#endif

namespace {
std::mutex work_mutex, identity_mutex;
std::atomic<bool> cancelled{false}, busy{false};
std::string active_id, cancelled_id;
constexpr int context_limit = 2048, output_limit = 384, batch_limit = 128;
constexpr size_t text_limit = 20000, answer_bytes = 9600;
using Clock = std::chrono::steady_clock;
double elapsed(Clock::time_point start) {
  return std::chrono::duration<double, std::milli>(Clock::now() - start).count();
}
bool bounded(const char *value, size_t limit, bool empty = false) {
  if (!value) return false;
  const size_t n = strnlen(value, limit + 1);
  return (empty || n > 0) && n <= limit;
}
struct ActiveScope {
  explicit ActiveScope(const char *id) {
    std::lock_guard<std::mutex> lock(identity_mutex);
    active_id = id; cancelled.store(cancelled_id == id); busy.store(true);
  }
  ~ActiveScope() {
    std::lock_guard<std::mutex> lock(identity_mutex);
    active_id.clear(); busy.store(false);
  }
};
#if HOMI_LLAMA_TRIAL
llama_model *model = nullptr;
std::string model_path;
int model_gpu = 0;
std::once_flag initialized;
bool abort_decode(void *) { return cancelled.load(); }
bool load_progress(float, void *) { return !cancelled.load(); }
void quiet_log(ggml_log_level, const char *, void *) {}
bool add_tokens(const llama_vocab *vocab, const std::string &text,
                bool special, std::vector<llama_token> &tokens) {
  const int n = llama_tokenize(vocab, text.data(), (int)text.size(), nullptr, 0,
                               false, special);
  if (n >= 0 || -n > context_limit - output_limit) return false;
  std::vector<llama_token> part((size_t)-n);
  const int count = llama_tokenize(vocab, text.data(), (int)text.size(),
                                    part.data(), (int)part.size(), false, special);
  if (count < 0 || tokens.size() + count > context_limit - output_limit) return false;
  tokens.insert(tokens.end(), part.begin(), part.begin() + count);
  return true;
}
#endif
}

extern "C" const char *homi_llm_runtime_id(void) {
  return "llama.cpp:b11889:d854d98bae598388ecea1ed84396587e5edc326d";
}
extern "C" int homi_llm_busy(void) { return busy.load() ? 1 : 0; }
extern "C" void homi_llm_cancel(const char *id) {
  if (!bounded(id, 64)) return;
  std::lock_guard<std::mutex> lock(identity_mutex);
  cancelled_id = id;
  if (active_id == id) cancelled.store(true);
}
extern "C" int homi_llm_unload(void) {
  std::unique_lock<std::mutex> lock(work_mutex, std::try_to_lock);
  if (!lock.owns_lock()) return HOMI_BUSY;
#if HOMI_LLAMA_TRIAL
  if (model) llama_model_free(model);
  model = nullptr; model_path.clear();
#endif
  return HOMI_OK;
}
extern "C" int homi_llm_generate(const char *id, const char *path,
    const char *system, const char *prompt, int gpu, char *output,
    size_t capacity, homi_llm_metrics *metrics) {
  if (!bounded(id, 64) || !bounded(path, 4096) || !bounded(system, text_limit) ||
      !bounded(prompt, text_limit) || std::strlen(system) + std::strlen(prompt) > text_limit ||
      !output || capacity < answer_bytes + 1 || !metrics || (gpu != 0 && gpu != 1)) {
    return HOMI_INVALID_INPUT;
  }
  output[0] = '\0'; *metrics = {};
#if !HOMI_LLAMA_TRIAL
  return HOMI_UNSUPPORTED;
#else
  std::unique_lock<std::mutex> lock(work_mutex, std::try_to_lock);
  if (!lock.owns_lock()) return HOMI_BUSY;
  ActiveScope active(id);
  const auto started = Clock::now();
  try {
    std::call_once(initialized, [] { llama_log_set(quiet_log, nullptr); llama_backend_init(); });
    if (!model || model_path != path || model_gpu != gpu) {
      if (model) llama_model_free(model);
      model = nullptr; model_path.clear();
      auto params = llama_model_default_params();
      params.n_gpu_layers = gpu ? 999 : 0;
      params.progress_callback = load_progress;
      model = llama_model_load_from_file(path, params);
      if (cancelled.load()) { if (model) llama_model_free(model); model = nullptr; return HOMI_CANCELLED; }
      if (!model) return HOMI_INVALID_MODEL;
      model_path = path; model_gpu = gpu;
    }
    const auto *vocab = llama_model_get_vocab(model);
    std::vector<llama_token> tokens;
    if (!add_tokens(vocab, "<|im_start|>system\n", true, tokens) ||
        !add_tokens(vocab, system, false, tokens) ||
        !add_tokens(vocab, "<|im_end|>\n<|im_start|>user\n", true, tokens) ||
        !add_tokens(vocab, prompt, false, tokens) ||
        !add_tokens(vocab, "<|im_end|>\n<|im_start|>assistant\n<think>\n\n</think>\n\n", true, tokens)) {
      return HOMI_CONTEXT_LIMIT;
    }
    metrics->prompt_tokens = (int)tokens.size();
    auto params = llama_context_default_params();
    params.n_ctx = context_limit; params.n_batch = batch_limit; params.n_ubatch = batch_limit;
    params.n_threads = 4; params.n_threads_batch = 4;
    params.abort_callback = abort_decode; params.abort_callback_data = nullptr;
    std::unique_ptr<llama_context, decltype(&llama_free)> context(llama_init_from_model(model, params), llama_free);
    if (!context) return HOMI_FAILED;
    for (size_t start = 0; start < tokens.size(); start += batch_limit) {
      if (cancelled.load()) return HOMI_CANCELLED;
      const auto count = (int)std::min<size_t>(batch_limit, tokens.size() - start);
      if (llama_decode(context.get(), llama_batch_get_one(tokens.data() + start, count)) != 0) {
        return cancelled.load() ? HOMI_CANCELLED : HOMI_FAILED;
      }
    }
    std::unique_ptr<llama_sampler, decltype(&llama_sampler_free)> sampler(
        llama_sampler_chain_init(llama_sampler_chain_default_params()), llama_sampler_free);
    llama_sampler_chain_add(sampler.get(), llama_sampler_init_top_k(20));
    llama_sampler_chain_add(sampler.get(), llama_sampler_init_top_p(0.8f, 1));
    llama_sampler_chain_add(sampler.get(), llama_sampler_init_penalties(
        llama_vocab_n_tokens(vocab), 256, 1.0f, 0.0f, 1.5f));
    llama_sampler_chain_add(sampler.get(), llama_sampler_init_temp(0.7f));
    llama_sampler_chain_add(sampler.get(), llama_sampler_init_dist(42));
    std::string text;
    for (int i = 0; i < output_limit; ++i) {
      if (cancelled.load() || elapsed(started) > 55000) return HOMI_CANCELLED;
      auto token = llama_sampler_sample(sampler.get(), context.get(), -1);
      if (llama_vocab_is_eog(vocab, token)) break;
      char piece[1024];
      const int n = llama_token_to_piece(vocab, token, piece, sizeof(piece), 0, false);
      if (n < 0 || text.size() + n > answer_bytes) return HOMI_FAILED;
      text.append(piece, (size_t)n);
      if (metrics->output_tokens++ == 0) metrics->first_token_ms = elapsed(started);
      if (llama_decode(context.get(), llama_batch_get_one(&token, 1)) != 0) {
        return cancelled.load() ? HOMI_CANCELLED : HOMI_FAILED;
      }
    }
    if (cancelled.load()) return HOMI_CANCELLED;
    if (text.empty() || text.find("<think>") != std::string::npos ||
        text.find("</think>") != std::string::npos || text.find("<|im_") != std::string::npos) return HOMI_FAILED;
    std::memcpy(output, text.data(), text.size()); output[text.size()] = '\0';
    metrics->total_ms = elapsed(started);
    return HOMI_OK;
  } catch (...) { output[0] = '\0'; return HOMI_FAILED; }
#endif
}
