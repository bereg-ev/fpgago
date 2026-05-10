# Five-in-a-Row — RISC2 platform
#
# Layout (relative to this file):
#   ../..            project root with portable game.c / render.c / *.h
#   ../../../..      repo root (4 levels up; arch/risc2/build.mk lives there)
#
# Override the build.mk defaults so they look at ../.. instead of the old
# ../../engine + ../../hal layout, then defer to the shared build pipeline.
REPO_ROOT    = ../../../../
INCLUDE_DIRS = ../.. . $(ARCH_DIR)
VPATH_DIRS   = . ../..
GAME_SRCS    = game.c render.c hal_risc2.c main.c

include $(REPO_ROOT)arch/risc2/build.mk
