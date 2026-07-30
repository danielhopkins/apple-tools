# appintents-dump — development-only App Intents schema reader.
# Not part of the shipped `apple` CLI; build it here when you need it.

BIN  := appintents-dump
SRC  := appintents-dump.m
CC   ?= clang

$(BIN): $(SRC)
	$(CC) -fobjc-arc -Wall -O2 \
		-framework Foundation -framework AppKit \
		$(SRC) -o $(BIN)

.PHONY: run clean
run: $(BIN)
	./$(BIN)

clean:
	rm -f $(BIN)
