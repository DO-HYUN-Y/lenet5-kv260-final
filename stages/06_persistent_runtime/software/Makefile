CC ?= gcc
CFLAGS ?= -O2 -g -Wall -Wextra -Werror -std=c11
UAPI_DIR ?= ../../04_linux_board_bringup/driver
CPPFLAGS ?= -I$(UAPI_DIR)

.PHONY: all clean

all: lenet5_persistent_runtime

lenet5_persistent_runtime: lenet5_persistent_runtime.c
	$(CC) $(CPPFLAGS) $(CFLAGS) -o $@ $<

clean:
	$(RM) lenet5_persistent_runtime
