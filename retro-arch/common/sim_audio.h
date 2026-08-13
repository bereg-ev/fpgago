/*
 * sim_audio.h — shared audio capture for the retro-arch desktop sims
 * (c64 SID, c16/plus4 TED — anything exposing soc.audio_pcm).
 *
 * The soc's audio_pcm output is one signed 16-bit sample per CPU-ish
 * cycle; the sim samples it once per sim-µs (call sim_audio_sample()
 * from the per-µs block of the main loop) and a ÷20 box average brings
 * it to a nominal 50 kHz:
 *
 *   --wav <path>   write the whole run as a mono 16-bit WAV on exit
 *   --audio        live SDL playback (stutters when the sim is slower
 *                  than realtime, but pitch is right)
 *
 * The WAV header says 50000 Hz; the true rate is (real cycle rate)/20 —
 * e.g. c64 phi 0.985248 MHz → 49262.4 Hz.  Scale measured frequencies
 * by (true/50000) when analyzing.
 *
 * Usage:
 *   sim_audio_parse_args(argc, argv);
 *   SDL_Init(SDL_INIT_VIDEO | sim_audio_sdl_flags());
 *   sim_audio_open();                      // no-op unless --audio
 *   ... per sim-µs:  sim_audio_sample((int16_t)top->audio_pcm);
 *   ... at exit:     sim_audio_finish();
 */

#ifndef SIM_AUDIO_H
#define SIM_AUDIO_H

#include <cstdio>
#include <cstdint>
#include <cstring>
#include <vector>
#include <SDL.h>

static const int   AUDIO_DECIM = 20;
static const int   AUDIO_RATE  = 1000000 / AUDIO_DECIM;   /* nominal */
static const char* g_wav_path  = nullptr;
static bool        g_sdl_audio = false;
static SDL_AudioDeviceID    g_audio_dev = 0;
static std::vector<int16_t> g_wav_buf;
static int32_t     g_aud_acc = 0;
static int         g_aud_cnt = 0;

static inline void sim_audio_parse_args(int argc, char** argv)
{
    for (int i = 1; i < argc; i++) {
        if      (!strcmp(argv[i], "--wav") && i+1 < argc) g_wav_path = argv[++i];
        else if (!strcmp(argv[i], "--audio"))             g_sdl_audio = true;
    }
}

static inline uint32_t sim_audio_sdl_flags(void)
{
    return g_sdl_audio ? SDL_INIT_AUDIO : 0;
}

static inline void sim_audio_open(void)
{
    if (!g_sdl_audio) return;
    SDL_AudioSpec want = {}, have = {};
    want.freq = AUDIO_RATE;
    want.format = AUDIO_S16SYS;
    want.channels = 1;
    want.samples = 2048;
    g_audio_dev = SDL_OpenAudioDevice(nullptr, 0, &want, &have, 0);
    if (!g_audio_dev)
        fprintf(stderr, "audio: SDL_OpenAudioDevice: %s\n", SDL_GetError());
    else
        SDL_PauseAudioDevice(g_audio_dev, 0);
}

static inline void sim_audio_sample(int16_t s)
{
    if (!g_wav_path && !g_audio_dev) return;
    g_aud_acc += s;
    if (++g_aud_cnt < AUDIO_DECIM) return;
    int16_t avg = (int16_t)(g_aud_acc / AUDIO_DECIM);
    g_aud_acc = 0; g_aud_cnt = 0;
    if (g_wav_path) g_wav_buf.push_back(avg);
    if (g_audio_dev) {
        static int16_t chunk[512];
        static int fill = 0;
        chunk[fill++] = avg;
        if (fill == 512) {
            SDL_QueueAudio(g_audio_dev, chunk, sizeof(chunk));
            fill = 0;
        }
    }
}

static inline void sim_audio_finish(void)
{
    if (!g_wav_path) return;
    FILE* f = fopen(g_wav_path, "wb");
    if (!f) { fprintf(stderr, "wav: cannot open %s\n", g_wav_path); return; }
    uint32_t rate = AUDIO_RATE;
    uint32_t dlen = (uint32_t)(g_wav_buf.size() * 2);
    uint32_t rlen = 36 + dlen, byterate = rate * 2;
    uint16_t balign = 2, bits = 16, fmt = 1, ch = 1;
    uint32_t fmtlen = 16;
    fwrite("RIFF", 1, 4, f); fwrite(&rlen, 4, 1, f); fwrite("WAVE", 1, 4, f);
    fwrite("fmt ", 1, 4, f); fwrite(&fmtlen, 4, 1, f);
    fwrite(&fmt, 2, 1, f);  fwrite(&ch, 2, 1, f);
    fwrite(&rate, 4, 1, f); fwrite(&byterate, 4, 1, f);
    fwrite(&balign, 2, 1, f); fwrite(&bits, 2, 1, f);
    fwrite("data", 1, 4, f); fwrite(&dlen, 4, 1, f);
    fwrite(g_wav_buf.data(), 2, g_wav_buf.size(), f);
    fclose(f);
    fprintf(stderr, "wav: wrote %s (%zu samples, %u Hz, %.2f s)\n",
            g_wav_path, g_wav_buf.size(), rate,
            (double)g_wav_buf.size() / rate);
}

#endif /* SIM_AUDIO_H */
