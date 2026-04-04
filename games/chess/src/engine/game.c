/*
 * game.c — Chess engine + AI with configurable search features
 *
 * Features (each toggle-able via ai_config_t):
 *   - Alpha-beta pruning
 *   - Move ordering (MVV-LVA for captures, hash move first)
 *   - Iterative deepening (principal variation)
 *   - Piece-square tables (positional evaluation)
 *   - Transposition table (hash table)
 *
 * RISC2 compatible: int-only types, no switch, no %, no memset.
 */

#include "game.h"

/* ── Helpers ─────────────────────────────────────────────────────────── */
static int sq_row(int sq) { return sq >> 3; }
static int sq_col(int sq) { return sq & 7; }
static int sq_ok(int r, int c) { return (unsigned)r < 8 && (unsigned)c < 8; }
static int sq_make(int r, int c) { return (r << 3) | c; }

/* ── Piece values ────────────────────────────────────────────────────── */
static const int piece_val[7] = { 0, 100, 320, 330, 500, 900, 20000 };

/* ── Piece-square tables (from white's perspective, index 0=a8) ────── */
/* For black: use pst[type][sq ^ 56] */
static const int pst[7][64] = {
{ /* EMPTY — unused */
  0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,
  0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0 },
{ /* PAWN */
   0,  0,  0,  0,  0,  0,  0,  0,
  50, 50, 50, 50, 50, 50, 50, 50,
  10, 10, 20, 30, 30, 20, 10, 10,
   5,  5, 10, 25, 25, 10,  5,  5,
   0,  0,  0, 20, 20,  0,  0,  0,
   5, -5,-10,  0,  0,-10, -5,  5,
   5, 10, 10,-20,-20, 10, 10,  5,
   0,  0,  0,  0,  0,  0,  0,  0 },
{ /* KNIGHT */
  -50,-40,-30,-30,-30,-30,-40,-50,
  -40,-20,  0,  0,  0,  0,-20,-40,
  -30,  0, 10, 15, 15, 10,  0,-30,
  -30,  5, 15, 20, 20, 15,  5,-30,
  -30,  0, 15, 20, 20, 15,  0,-30,
  -30,  5, 10, 15, 15, 10,  5,-30,
  -40,-20,  0,  5,  5,  0,-20,-40,
  -50,-40,-30,-30,-30,-30,-40,-50 },
{ /* BISHOP */
  -20,-10,-10,-10,-10,-10,-10,-20,
  -10,  0,  0,  0,  0,  0,  0,-10,
  -10,  0, 10, 10, 10, 10,  0,-10,
  -10,  5,  5, 10, 10,  5,  5,-10,
  -10,  0, 10, 10, 10, 10,  0,-10,
  -10, 10, 10, 10, 10, 10, 10,-10,
  -10,  5,  0,  0,  0,  0,  5,-10,
  -20,-10,-10,-10,-10,-10,-10,-20 },
{ /* ROOK */
    0,  0,  0,  0,  0,  0,  0,  0,
    5, 10, 10, 10, 10, 10, 10,  5,
   -5,  0,  0,  0,  0,  0,  0, -5,
   -5,  0,  0,  0,  0,  0,  0, -5,
   -5,  0,  0,  0,  0,  0,  0, -5,
   -5,  0,  0,  0,  0,  0,  0, -5,
   -5,  0,  0,  0,  0,  0,  0, -5,
    0,  0,  0,  5,  5,  0,  0,  0 },
{ /* QUEEN */
  -20,-10,-10, -5, -5,-10,-10,-20,
  -10,  0,  0,  0,  0,  0,  0,-10,
  -10,  0,  5,  5,  5,  5,  0,-10,
   -5,  0,  5,  5,  5,  5,  0, -5,
    0,  0,  5,  5,  5,  5,  0, -5,
  -10,  5,  5,  5,  5,  5,  0,-10,
  -10,  0,  5,  0,  0,  0,  0,-10,
  -20,-10,-10, -5, -5,-10,-10,-20 },
{ /* KING (midgame) */
  -30,-40,-40,-50,-50,-40,-40,-30,
  -30,-40,-40,-50,-50,-40,-40,-30,
  -30,-40,-40,-50,-50,-40,-40,-30,
  -30,-40,-40,-50,-50,-40,-40,-30,
  -20,-30,-30,-40,-40,-30,-30,-20,
  -10,-20,-20,-20,-20,-20,-20,-10,
   20, 20,  0,  0,  0,  0, 20, 20,
   20, 30, 10,  0,  0, 10, 30, 20 }
};

/* ── Direction tables ────────────────────────────────────────────────── */
static const int knight_dr[8] = {-2,-2,-1,-1, 1, 1, 2, 2};
static const int knight_dc[8] = {-1, 1,-2, 2,-2, 2,-1, 1};
static const int king_dr[8]   = {-1,-1,-1, 0, 0, 1, 1, 1};
static const int king_dc[8]   = {-1, 0, 1,-1, 1,-1, 0, 1};
static const int bishop_dr[4] = {-1,-1, 1, 1};
static const int bishop_dc[4] = {-1, 1,-1, 1};
static const int rook_dr[4]   = {-1, 1, 0, 0};
static const int rook_dc[4]   = { 0, 0,-1, 1};

/* ── Zobrist hashing ─────────────────────────────────────────────────── */
#ifdef RISC2_PLATFORM
/* Fixed data RAM addresses (gcasm has no .bss support).
 * Layout: 0x011000 zob_piece[64][15], then side, castle[16], ep[8], ready */
#define zob_piece  ((unsigned int(*)[15])0x011000)
#define zob_side   (*(unsigned int*)0x011F00)
#define zob_castle ((unsigned int*)0x011F04)
#define zob_ep     ((unsigned int*)0x011F44)
#define zob_ready  (*(int*)0x011F64)
#else
static unsigned int zob_piece[64][15];
static unsigned int zob_side;
static unsigned int zob_castle[16];
static unsigned int zob_ep[8];
static int zob_ready = 0;
#endif

static void init_zobrist(void)
{
    unsigned int s = 0x91E2A3B7;
    int i, j;
    for (i = 0; i < 64; i++)
        for (j = 0; j < 15; j++) {
            s = s * 1103515245 + 12345;
            zob_piece[i][j] = s;
        }
    s = s * 1103515245 + 12345; zob_side = s;
    for (i = 0; i < 16; i++) { s = s * 1103515245 + 12345; zob_castle[i] = s; }
    for (i = 0; i < 8; i++)  { s = s * 1103515245 + 12345; zob_ep[i] = s; }
    zob_ready = 1;
}

static unsigned int compute_hash(const game_t *g)
{
    unsigned int h = 0;
    int i;
    for (i = 0; i < 64; i++)
        if (g->board[i]) h ^= zob_piece[i][g->board[i]];
    if (g->side == BLACK) h ^= zob_side;
    h ^= zob_castle[g->castle];
    if (g->ep_square >= 0) h ^= zob_ep[g->ep_square & 7];
    return h;
}

/* ── Transposition table ─────────────────────────────────────────────── */
#define TT_EXACT 0
#define TT_LOWER 1
#define TT_UPPER 2

typedef struct {
    unsigned int key;
    int score;
    int best_move;
    int depth;
    int flag;
} tt_entry_t;

#ifdef RISC2_PLATFORM
/* TT disabled on RISC2 — too large for on-chip RAM */
#define TT_BITS  0
#define TT_SIZE  1
#define TT_MASK  0
static tt_entry_t tt_dummy;
#define tt (&tt_dummy)
static void clear_tt(void) { tt_dummy.key = 0; tt_dummy.depth = -1; }
#else
#define TT_BITS  16
#define TT_SIZE  (1 << TT_BITS)
#define TT_MASK  (TT_SIZE - 1)
static tt_entry_t tt[TT_SIZE];

static void clear_tt(void)
{
    int i;
    for (i = 0; i < TT_SIZE; i++) {
        tt[i].key = 0;
        tt[i].depth = -1;
    }
}
#endif

/* ── Attack detection ────────────────────────────────────────────────── */
/* Returns 1 if square sq is attacked by any piece of color 'by' */
static int is_attacked(const int *board, int sq, int by)
{
    int r = sq_row(sq), c = sq_col(sq);
    int i, nr, nc, nsq, piece, type;

    /* Pawn attacks — pawns of 'by' that can capture onto sq */
    {
        int pr = r + (by == WHITE ? 1 : -1);
        if ((unsigned)pr < 8) {
            if (c > 0 && board[sq_make(pr, c - 1)] == PIECE_MAKE(PAWN, by)) return 1;
            if (c < 7 && board[sq_make(pr, c + 1)] == PIECE_MAKE(PAWN, by)) return 1;
        }
    }

    /* Knight */
    for (i = 0; i < 8; i++) {
        nr = r + knight_dr[i]; nc = c + knight_dc[i];
        if (sq_ok(nr, nc) && board[sq_make(nr, nc)] == PIECE_MAKE(KNIGHT, by))
            return 1;
    }

    /* King */
    for (i = 0; i < 8; i++) {
        nr = r + king_dr[i]; nc = c + king_dc[i];
        if (sq_ok(nr, nc) && board[sq_make(nr, nc)] == PIECE_MAKE(KING, by))
            return 1;
    }

    /* Diagonal sliders (bishop + queen) */
    for (i = 0; i < 4; i++) {
        nr = r + bishop_dr[i]; nc = c + bishop_dc[i];
        while (sq_ok(nr, nc)) {
            nsq = sq_make(nr, nc); piece = board[nsq];
            if (piece) {
                if (PIECE_COLOR(piece) == by) {
                    type = PIECE_TYPE(piece);
                    if (type == BISHOP || type == QUEEN) return 1;
                }
                break;
            }
            nr += bishop_dr[i]; nc += bishop_dc[i];
        }
    }

    /* Orthogonal sliders (rook + queen) */
    for (i = 0; i < 4; i++) {
        nr = r + rook_dr[i]; nc = c + rook_dc[i];
        while (sq_ok(nr, nc)) {
            nsq = sq_make(nr, nc); piece = board[nsq];
            if (piece) {
                if (PIECE_COLOR(piece) == by) {
                    type = PIECE_TYPE(piece);
                    if (type == ROOK || type == QUEEN) return 1;
                }
                break;
            }
            nr += rook_dr[i]; nc += rook_dc[i];
        }
    }

    return 0;
}

/* ── Move generation (pseudo-legal) ──────────────────────────────────── */
static int gen_moves(const game_t *g, int *moves)
{
    int n = 0;
    int side = g->side, opp = side ^ 1;
    int sq, r, c, nr, nc, nsq, piece, target, type, i;

    for (sq = 0; sq < 64; sq++) {
        piece = g->board[sq];
        if (!piece || PIECE_COLOR(piece) != side) continue;
        r = sq_row(sq); c = sq_col(sq);
        type = PIECE_TYPE(piece);

        if (type == PAWN) {
            int dir = (side == WHITE) ? -1 : 1;
            int start_r = (side == WHITE) ? 6 : 1;
            int promo_r = (side == WHITE) ? 0 : 7;
            nr = r + dir;
            /* forward one */
            nsq = sq_make(nr, c);
            if (g->board[nsq] == EMPTY) {
                if (nr == promo_r) {
                    moves[n++] = MV(sq, nsq, MF_PROMO_Q);
                    moves[n++] = MV(sq, nsq, MF_PROMO_R);
                    moves[n++] = MV(sq, nsq, MF_PROMO_B);
                    moves[n++] = MV(sq, nsq, MF_PROMO_N);
                } else {
                    moves[n++] = MV(sq, nsq, MF_NORMAL);
                    /* forward two */
                    if (r == start_r) {
                        nsq = sq_make(r + 2 * dir, c);
                        if (g->board[nsq] == EMPTY)
                            moves[n++] = MV(sq, nsq, MF_PAWN2);
                    }
                }
            }
            /* captures */
            for (i = -1; i <= 1; i += 2) {
                nc = c + i;
                if (nc < 0 || nc > 7) continue;
                nsq = sq_make(nr, nc);
                target = g->board[nsq];
                if (target && PIECE_COLOR(target) == opp) {
                    if (nr == promo_r) {
                        moves[n++] = MV(sq, nsq, MF_PROMO_Q);
                        moves[n++] = MV(sq, nsq, MF_PROMO_R);
                        moves[n++] = MV(sq, nsq, MF_PROMO_B);
                        moves[n++] = MV(sq, nsq, MF_PROMO_N);
                    } else {
                        moves[n++] = MV(sq, nsq, MF_NORMAL);
                    }
                }
                if (nsq == g->ep_square)
                    moves[n++] = MV(sq, nsq, MF_EP);
            }
        }
        else if (type == KNIGHT) {
            for (i = 0; i < 8; i++) {
                nr = r + knight_dr[i]; nc = c + knight_dc[i];
                if (!sq_ok(nr, nc)) continue;
                nsq = sq_make(nr, nc); target = g->board[nsq];
                if (!target || PIECE_COLOR(target) == opp)
                    moves[n++] = MV(sq, nsq, MF_NORMAL);
            }
        }
        else if (type == KING) {
            for (i = 0; i < 8; i++) {
                nr = r + king_dr[i]; nc = c + king_dc[i];
                if (!sq_ok(nr, nc)) continue;
                nsq = sq_make(nr, nc); target = g->board[nsq];
                if (!target || PIECE_COLOR(target) == opp)
                    moves[n++] = MV(sq, nsq, MF_NORMAL);
            }
            /* castling */
            if (side == WHITE) {
                if ((g->castle & CASTLE_WK) &&
                    !g->board[61] && !g->board[62] &&
                    !is_attacked(g->board, 60, BLACK) &&
                    !is_attacked(g->board, 61, BLACK) &&
                    !is_attacked(g->board, 62, BLACK))
                    moves[n++] = MV(60, 62, MF_CASTLE);
                if ((g->castle & CASTLE_WQ) &&
                    !g->board[59] && !g->board[58] && !g->board[57] &&
                    !is_attacked(g->board, 60, BLACK) &&
                    !is_attacked(g->board, 59, BLACK) &&
                    !is_attacked(g->board, 58, BLACK))
                    moves[n++] = MV(60, 58, MF_CASTLE);
            } else {
                if ((g->castle & CASTLE_BK) &&
                    !g->board[5] && !g->board[6] &&
                    !is_attacked(g->board, 4, WHITE) &&
                    !is_attacked(g->board, 5, WHITE) &&
                    !is_attacked(g->board, 6, WHITE))
                    moves[n++] = MV(4, 6, MF_CASTLE);
                if ((g->castle & CASTLE_BQ) &&
                    !g->board[3] && !g->board[2] && !g->board[1] &&
                    !is_attacked(g->board, 4, WHITE) &&
                    !is_attacked(g->board, 3, WHITE) &&
                    !is_attacked(g->board, 2, WHITE))
                    moves[n++] = MV(4, 2, MF_CASTLE);
            }
        }
        else {
            /* sliding pieces: bishop, rook, queen */
            if (type == BISHOP || type == QUEEN) {
                for (i = 0; i < 4; i++) {
                    nr = r + bishop_dr[i]; nc = c + bishop_dc[i];
                    while (sq_ok(nr, nc)) {
                        nsq = sq_make(nr, nc); target = g->board[nsq];
                        if (!target) { moves[n++] = MV(sq, nsq, MF_NORMAL); }
                        else { if (PIECE_COLOR(target) == opp) moves[n++] = MV(sq, nsq, MF_NORMAL); break; }
                        nr += bishop_dr[i]; nc += bishop_dc[i];
                    }
                }
            }
            if (type == ROOK || type == QUEEN) {
                for (i = 0; i < 4; i++) {
                    nr = r + rook_dr[i]; nc = c + rook_dc[i];
                    while (sq_ok(nr, nc)) {
                        nsq = sq_make(nr, nc); target = g->board[nsq];
                        if (!target) { moves[n++] = MV(sq, nsq, MF_NORMAL); }
                        else { if (PIECE_COLOR(target) == opp) moves[n++] = MV(sq, nsq, MF_NORMAL); break; }
                        nr += rook_dr[i]; nc += rook_dc[i];
                    }
                }
            }
        }
    }
    return n;
}

/* ── Make / unmake ───────────────────────────────────────────────────── */
static void make_move(game_t *g, int mv)
{
    int from = MV_FROM(mv), to = MV_TO(mv), fl = MV_FLAGS(mv);
    int piece = g->board[from], captured = g->board[to];
    undo_t *u = &g->undo[g->undo_sp++];

    u->captured = captured;
    u->castle = g->castle;
    u->ep_square = g->ep_square;
    u->hash = g->hash;

    /* hash: remove piece from 'from' */
    g->hash ^= zob_piece[from][piece];
    if (captured) g->hash ^= zob_piece[to][captured];

    g->board[to] = piece;
    g->board[from] = EMPTY;

    /* clear old ep from hash */
    if (g->ep_square >= 0) g->hash ^= zob_ep[g->ep_square & 7];
    g->ep_square = -1;

    if (fl == MF_EP) {
        int cap_sq = (g->side == WHITE) ? to + 8 : to - 8;
        g->hash ^= zob_piece[cap_sq][g->board[cap_sq]];
        g->board[cap_sq] = EMPTY;
        /* hash: add piece to 'to' as pawn */
        g->hash ^= zob_piece[to][piece];
    }
    else if (fl == MF_PAWN2) {
        g->ep_square = (from + to) >> 1;
        g->hash ^= zob_ep[g->ep_square & 7];
        g->hash ^= zob_piece[to][piece];
    }
    else if (fl == MF_CASTLE) {
        int rf, rt, rook;
        if (to > from) { rf = from + 3; rt = from + 1; }
        else            { rf = from - 4; rt = from - 1; }
        rook = g->board[rf];
        g->hash ^= zob_piece[rf][rook];
        g->hash ^= zob_piece[rt][rook];
        g->board[rt] = rook;
        g->board[rf] = EMPTY;
        g->hash ^= zob_piece[to][piece];
    }
    else if (fl >= MF_PROMO_Q && fl <= MF_PROMO_N) {
        int pt;
        if (fl == MF_PROMO_Q) pt = QUEEN;
        else if (fl == MF_PROMO_R) pt = ROOK;
        else if (fl == MF_PROMO_B) pt = BISHOP;
        else pt = KNIGHT;
        g->board[to] = PIECE_MAKE(pt, g->side);
        g->hash ^= zob_piece[to][g->board[to]];
    }
    else {
        g->hash ^= zob_piece[to][piece];
    }

    /* update castling rights */
    g->hash ^= zob_castle[g->castle];
    if (PIECE_TYPE(piece) == KING) {
        g->king_sq[g->side] = to;
        if (g->side == WHITE) g->castle &= ~(CASTLE_WK | CASTLE_WQ);
        else                  g->castle &= ~(CASTLE_BK | CASTLE_BQ);
    }
    if (from == 56 || to == 56) g->castle &= ~CASTLE_WQ;
    if (from == 63 || to == 63) g->castle &= ~CASTLE_WK;
    if (from ==  0 || to ==  0) g->castle &= ~CASTLE_BQ;
    if (from ==  7 || to ==  7) g->castle &= ~CASTLE_BK;
    g->hash ^= zob_castle[g->castle];

    g->side ^= 1;
    g->hash ^= zob_side;
    g->ply++;
}

static void unmake_move(game_t *g, int mv)
{
    int from = MV_FROM(mv), to = MV_TO(mv), fl = MV_FLAGS(mv);
    int piece;

    g->ply--;
    g->side ^= 1;
    g->undo_sp--;

    piece = g->board[to];
    if (fl >= MF_PROMO_Q && fl <= MF_PROMO_N)
        piece = PIECE_MAKE(PAWN, g->side);

    g->board[from] = piece;
    g->board[to] = g->undo[g->undo_sp].captured;

    if (fl == MF_EP) {
        int cap_sq = (g->side == WHITE) ? to + 8 : to - 8;
        g->board[cap_sq] = PIECE_MAKE(PAWN, g->side ^ 1);
    }
    else if (fl == MF_CASTLE) {
        int rf, rt;
        if (to > from) { rf = from + 3; rt = from + 1; }
        else            { rf = from - 4; rt = from - 1; }
        g->board[rf] = g->board[rt];
        g->board[rt] = EMPTY;
    }

    if (PIECE_TYPE(piece) == KING)
        g->king_sq[g->side] = from;

    g->castle = g->undo[g->undo_sp].castle;
    g->ep_square = g->undo[g->undo_sp].ep_square;
    g->hash = g->undo[g->undo_sp].hash;
}

/* ── Evaluation ──────────────────────────────────────────────────────── */
static int evaluate(const game_t *g)
{
    int score = 0, sq, piece, type, color, psq;
    for (sq = 0; sq < 64; sq++) {
        piece = g->board[sq];
        if (!piece) continue;
        type = PIECE_TYPE(piece);
        color = PIECE_COLOR(piece);
        psq = (color == WHITE) ? sq : (sq ^ 56);
        if (color == WHITE)
            score += piece_val[type] + (g->ai.use_pst ? pst[type][psq] : 0);
        else
            score -= piece_val[type] + (g->ai.use_pst ? pst[type][psq] : 0);
    }
    return (g->side == WHITE) ? score : -score;
}

/* ── Move ordering ───────────────────────────────────────────────────── */
static void order_moves(const game_t *g, int *moves, int n, int hash_move)
{
    int scores[MAX_MOVES];
    int i, j, tmp;
    for (i = 0; i < n; i++) {
        if (moves[i] == hash_move) {
            scores[i] = 1000000;
        } else {
            int to = MV_TO(moves[i]);
            int cap = g->board[to];
            int fl = MV_FLAGS(moves[i]);
            if (fl == MF_EP) {
                scores[i] = 10500;  /* en passant = pawn captures pawn */
            } else if (cap) {
                int from_t = PIECE_TYPE(g->board[MV_FROM(moves[i])]);
                scores[i] = 10000 + piece_val[PIECE_TYPE(cap)] * 10 - piece_val[from_t];
            } else if (fl >= MF_PROMO_Q && fl <= MF_PROMO_N) {
                scores[i] = (fl == MF_PROMO_Q) ? 9000 : 5000;
            } else {
                scores[i] = 0;
            }
        }
    }
    /* insertion sort (efficient for ~30-50 moves) */
    for (i = 1; i < n; i++) {
        int ks = scores[i], km = moves[i];
        j = i - 1;
        while (j >= 0 && scores[j] < ks) {
            scores[j + 1] = scores[j];
            moves[j + 1] = moves[j];
            j--;
        }
        scores[j + 1] = ks;
        moves[j + 1] = km;
    }
    (void)tmp;
}

/* ── Search ──────────────────────────────────────────────────────────── */
#define INF 100000

static int search(game_t *g, int depth, int alpha, int beta)
{
    int moves[MAX_MOVES];
    int nmoves, i, score, best_score, best_move;
    int orig_alpha = alpha;
    int legal = 0;
    int hash_move = 0;

    /* TT probe */
    if (g->ai.use_tt) {
        tt_entry_t *e = &tt[g->hash & TT_MASK];
        if (e->key == g->hash && e->depth >= depth) {
            if (e->flag == TT_EXACT) return e->score;
            if (g->ai.use_alpha_beta) {
                if (e->flag == TT_LOWER && e->score > alpha) alpha = e->score;
                else if (e->flag == TT_UPPER && e->score < beta) beta = e->score;
                if (alpha >= beta) return e->score;
            }
        }
        if (e->key == g->hash) hash_move = e->best_move;
    }

    if (depth <= 0)
        return evaluate(g);

    nmoves = gen_moves(g, moves);

    if (g->ai.use_move_order)
        order_moves(g, moves, nmoves, hash_move);

    best_score = -INF;
    best_move = 0;

    for (i = 0; i < nmoves; i++) {
        make_move(g, moves[i]);

        /* legality: own king must not be in check */
        if (is_attacked(g->board, g->king_sq[g->side ^ 1], g->side)) {
            unmake_move(g, moves[i]);
            continue;
        }
        legal++;
        g->nodes++;

        if (g->ai.use_alpha_beta)
            score = -search(g, depth - 1, -beta, -alpha);
        else
            score = -search(g, depth - 1, -INF, INF);

        unmake_move(g, moves[i]);

        if (score > best_score) {
            best_score = score;
            best_move = moves[i];
        }
        if (g->ai.use_alpha_beta && score > alpha) {
            alpha = score;
            if (alpha >= beta) break;
        }
    }

    /* no legal moves: checkmate or stalemate */
    if (legal == 0) {
        if (is_attacked(g->board, g->king_sq[g->side], g->side ^ 1))
            return -(INF - g->ply);
        return 0;
    }

    /* TT store */
    if (g->ai.use_tt) {
        tt_entry_t *e = &tt[g->hash & TT_MASK];
        if (depth >= e->depth) {
            e->key = g->hash;
            e->score = best_score;
            e->best_move = best_move;
            e->depth = depth;
            if (best_score <= orig_alpha) e->flag = TT_UPPER;
            else if (best_score >= beta)  e->flag = TT_LOWER;
            else                          e->flag = TT_EXACT;
        }
    }

    return best_score;
}

static int ai_search(game_t *g)
{
    int best = 0, depth;
    int moves[MAX_MOVES];
    int nmoves, i, score, best_score;
    int hash_move = 0;
    int max_d = g->ai.max_depth;
    int start_depth = g->ai.use_pv ? 1 : max_d;

    g->nodes = 0;

    for (depth = start_depth; depth <= max_d; depth++) {
        nmoves = gen_moves(g, moves);
        if (g->ai.use_move_order) {
            /* get hash move from TT for root ordering */
            if (g->ai.use_tt) {
                tt_entry_t *e = &tt[g->hash & TT_MASK];
                if (e->key == g->hash) hash_move = e->best_move;
            }
            order_moves(g, moves, nmoves, hash_move);
        }

        best_score = -INF;
        for (i = 0; i < nmoves; i++) {
            make_move(g, moves[i]);
            if (is_attacked(g->board, g->king_sq[g->side ^ 1], g->side)) {
                unmake_move(g, moves[i]);
                continue;
            }
            g->nodes++;

            if (g->ai.use_alpha_beta)
                score = -search(g, depth - 1, -INF, -best_score);
            else
                score = -search(g, depth - 1, -INF, INF);

            unmake_move(g, moves[i]);

            if (score > best_score) {
                best_score = score;
                best = moves[i];
            }
        }
    }
    return best;
}

/* ── Legal move helpers (for UI) ─────────────────────────────────────── */
static int gen_legal(game_t *g, int from_sq, int *out)
{
    int moves[MAX_MOVES];
    int nmoves = gen_moves(g, moves);
    int count = 0, i;
    for (i = 0; i < nmoves; i++) {
        if (from_sq >= 0 && MV_FROM(moves[i]) != from_sq) continue;
        make_move(g, moves[i]);
        if (!is_attacked(g->board, g->king_sq[g->side ^ 1], g->side))
            out[count++] = moves[i];
        unmake_move(g, moves[i]);
    }
    return count;
}

static int has_legal_moves(game_t *g)
{
    int moves[MAX_MOVES];
    int nmoves = gen_moves(g, moves);
    int i;
    for (i = 0; i < nmoves; i++) {
        make_move(g, moves[i]);
        if (!is_attacked(g->board, g->king_sq[g->side ^ 1], g->side)) {
            unmake_move(g, moves[i]);
            return 1;
        }
        unmake_move(g, moves[i]);
    }
    return 0;
}

static int find_move(const game_t *g, int from, int to)
{
    int i, best = 0;
    for (i = 0; i < g->num_legal; i++) {
        int m = g->legal_dests[i];
        if (MV_FROM(m) == from && MV_TO(m) == to) {
            if (MV_FLAGS(m) == MF_PROMO_Q) return m;
            if (!best) best = m;
        }
    }
    return best;
}

static void update_check(game_t *g)
{
    g->in_check = is_attacked(g->board, g->king_sq[g->side], g->side ^ 1);
}

static void check_game_over(game_t *g)
{
    if (!has_legal_moves(g)) {
        if (is_attacked(g->board, g->king_sq[g->side], g->side ^ 1))
            g->state = (g->side == WHITE) ? GS_BLACK_WINS : GS_WHITE_WINS;
        else
            g->state = GS_STALEMATE;
    }
    update_check(g);
}

/* ── Public interface ────────────────────────────────────────────────── */
static const int start_pos[64] = {
    B_ROOK, B_KNIGHT, B_BISHOP, B_QUEEN, B_KING, B_BISHOP, B_KNIGHT, B_ROOK,
    B_PAWN, B_PAWN,   B_PAWN,   B_PAWN,  B_PAWN, B_PAWN,   B_PAWN,   B_PAWN,
    0,0,0,0,0,0,0,0,  0,0,0,0,0,0,0,0,
    0,0,0,0,0,0,0,0,  0,0,0,0,0,0,0,0,
    W_PAWN, W_PAWN,   W_PAWN,   W_PAWN,  W_PAWN, W_PAWN,   W_PAWN,   W_PAWN,
    W_ROOK, W_KNIGHT, W_BISHOP, W_QUEEN, W_KING, W_BISHOP, W_KNIGHT, W_ROOK
};

void game_init(game_t *g)
{
    int i;
    if (!zob_ready) init_zobrist();

    for (i = 0; i < 64; i++) g->board[i] = start_pos[i];
    g->side = WHITE;
    g->castle = CASTLE_WK | CASTLE_WQ | CASTLE_BK | CASTLE_BQ;
    g->ep_square = -1;
    g->king_sq[WHITE] = 60;  /* e1 */
    g->king_sq[BLACK] = 4;   /* e8 */
    g->ply = 0;
    g->undo_sp = 0;
    g->hash = compute_hash(g);

    g->cursor = 52;  /* e2 */
    g->selected = -1;
    g->state = GS_PLAYING;
    g->last_from = -1;
    g->last_to = -1;
    g->num_legal = 0;
    g->in_check = 0;
    g->nodes = 0;

#ifdef RISC2_PLATFORM
    /* RISC2: reduced depth, no TT, no iterative deepening */
    g->ai.max_depth = 3;
    g->ai.use_alpha_beta = 1;
    g->ai.use_move_order = 1;
    g->ai.use_pv = 0;
    g->ai.use_pst = 1;
    g->ai.use_tt = 0;
#else
    /* default AI: all features on, depth 4 */
    g->ai.max_depth = 4;
    g->ai.use_alpha_beta = 1;
    g->ai.use_move_order = 1;
    g->ai.use_pv = 1;
    g->ai.use_pst = 1;
    g->ai.use_tt = 1;
#endif

    clear_tt();
}

void game_tick(game_t *g, int input)
{
    int r, c, sq, piece, mv;

    if (g->state != GS_PLAYING) {
        if (input == ' ' || input == '\r')
            game_init(g);
        return;
    }

    /* human is WHITE; skip input if it's black's turn (shouldn't happen) */
    if (g->side != WHITE) return;

    r = sq_row(g->cursor);
    c = sq_col(g->cursor);

    if (input == 'w') { if (r > 0) g->cursor -= 8; }
    else if (input == 's') { if (r < 7) g->cursor += 8; }
    else if (input == 'a') { if (c > 0) g->cursor -= 1; }
    else if (input == 'd') { if (c < 7) g->cursor += 1; }
    else if (input == ' ' || input == '\r') {
        sq = g->cursor;
        piece = g->board[sq];

        if (g->selected >= 0) {
            /* piece already selected */
            if (sq == g->selected) {
                /* deselect */
                g->selected = -1;
                g->num_legal = 0;
            } else {
                mv = find_move(g, g->selected, sq);
                if (mv) {
                    /* make human move */
                    make_move(g, mv);
                    g->last_from = MV_FROM(mv);
                    g->last_to = MV_TO(mv);
                    g->selected = -1;
                    g->num_legal = 0;
                    check_game_over(g);

                    /* AI response */
                    if (g->state == GS_PLAYING) {
                        mv = ai_search(g);
                        if (mv) {
                            make_move(g, mv);
                            g->last_from = MV_FROM(mv);
                            g->last_to = MV_TO(mv);
                        }
                        check_game_over(g);
                    }
                } else if (piece && PIECE_COLOR(piece) == g->side) {
                    /* select different piece */
                    g->selected = sq;
                    g->num_legal = gen_legal(g, sq, g->legal_dests);
                } else {
                    g->selected = -1;
                    g->num_legal = 0;
                }
            }
        } else {
            /* nothing selected: select own piece */
            if (piece && PIECE_COLOR(piece) == g->side) {
                g->selected = sq;
                g->num_legal = gen_legal(g, sq, g->legal_dests);
            }
        }
    }
}
