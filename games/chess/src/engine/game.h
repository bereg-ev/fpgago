/*
 * game.h — Chess engine with configurable AI
 *
 * Board: int board[64], index = row*8 + col
 *   row 0 = rank 8 (black back rank), row 7 = rank 1 (white back rank)
 *   col 0 = a-file, col 7 = h-file
 *
 * Piece encoding: type | (color << 3)
 *   White pieces: 1–6, Black pieces: 9–14
 *   Type: PAWN=1, KNIGHT=2, BISHOP=3, ROOK=4, QUEEN=5, KING=6
 *
 * Move encoding (packed int):
 *   bits 0–5: from square, bits 6–11: to square, bits 12–15: flags
 *
 * RISC2 compatible: int-only, no switch, no %, no string literals.
 */

#ifndef GAME_H
#define GAME_H

/* ── Piece types ─────────────────────────────────────────────────────── */
#define EMPTY   0
#define PAWN    1
#define KNIGHT  2
#define BISHOP  3
#define ROOK    4
#define QUEEN   5
#define KING    6

#define WHITE   0
#define BLACK   1

#define W_PAWN   1
#define W_KNIGHT 2
#define W_BISHOP 3
#define W_ROOK   4
#define W_QUEEN  5
#define W_KING   6
#define B_PAWN   9
#define B_KNIGHT 10
#define B_BISHOP 11
#define B_ROOK   12
#define B_QUEEN  13
#define B_KING   14

#define PIECE_TYPE(p)  ((p) & 7)
#define PIECE_COLOR(p) (((p) >> 3) & 1)
#define PIECE_MAKE(t,c) ((t) | ((c) << 3))
#define IS_BLACK(p)    ((p) & 8)

/* ── Move encoding ───────────────────────────────────────────────────── */
#define MV(f,t,fl)    ((f) | ((t) << 6) | ((fl) << 12))
#define MV_FROM(m)    ((m) & 63)
#define MV_TO(m)      (((m) >> 6) & 63)
#define MV_FLAGS(m)   (((m) >> 12) & 15)

#define MF_NORMAL  0
#define MF_EP      1
#define MF_CASTLE  2
#define MF_PROMO_Q 3
#define MF_PROMO_R 4
#define MF_PROMO_B 5
#define MF_PROMO_N 6
#define MF_PAWN2   7

/* ── Castle flags ────────────────────────────────────────────────────── */
#define CASTLE_WK  1
#define CASTLE_WQ  2
#define CASTLE_BK  4
#define CASTLE_BQ  8

/* ── Game states ─────────────────────────────────────────────────────── */
#define GS_PLAYING    0
#define GS_WHITE_WINS 1
#define GS_BLACK_WINS 2
#define GS_STALEMATE  3

#define MAX_MOVES  256
#ifdef RISC2_PLATFORM
#define MAX_UNDO   128
#else
#define MAX_UNDO   512
#endif

/* ── AI configuration ────────────────────────────────────────────────── */
typedef struct {
    int max_depth;
    int use_alpha_beta;
    int use_move_order;
    int use_pv;           /* iterative deepening */
    int use_pst;          /* piece-square tables */
    int use_tt;           /* transposition table */
} ai_config_t;

/* ── Undo record ─────────────────────────────────────────────────────── */
typedef struct {
    int captured;
    int castle;
    int ep_square;
    unsigned int hash;
} undo_t;

/* ── Game state ──────────────────────────────────────────────────────── */
typedef struct {
    int board[64];
    int side;              /* WHITE or BLACK to move */
    int castle;            /* castle flags */
    int ep_square;         /* en passant target, -1 if none */
    int king_sq[2];        /* king positions [WHITE], [BLACK] */
    unsigned int hash;     /* zobrist hash */
    int ply;               /* half-move clock */

    /* undo stack (shared by game moves and search) */
    undo_t undo[MAX_UNDO];
    int undo_sp;

    /* UI */
    int cursor;            /* cursor square 0–63 */
    int selected;          /* selected square, -1 if none */
    int state;             /* GS_PLAYING etc */
    int last_from;         /* last move highlight */
    int last_to;
    int legal_dests[MAX_MOVES]; /* legal moves for selected piece */
    int num_legal;
    int in_check;          /* is current side in check */

    /* AI */
    ai_config_t ai;
    int nodes;             /* search node counter */
} game_t;

void game_init(game_t *g);
void game_tick(game_t *g, int input);

#endif /* GAME_H */
