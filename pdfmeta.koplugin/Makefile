.PHONY: test

LUA_PATH := ./?.lua;./lib/?.lua;./lib/?/?.lua

test:
	LUA_PATH="$(LUA_PATH)" busted test
