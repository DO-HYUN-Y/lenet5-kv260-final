CC ?= gcc
CFLAGS ?= -O2 -g -Wall -Wextra -Werror -std=c11

.PHONY: all clean

all: lenet5_board_test

lenet5_board_test: lenet5_board_test.c ../driver/lenet5_board_uapi.h
	$(CC) $(CFLAGS) -o $@ lenet5_board_test.c

clean:
	$(RM) lenet5_board_test
