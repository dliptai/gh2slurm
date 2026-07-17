CC = gcc
TARGET = helloworld

all: $(TARGET)

$(TARGET): helloworld.c
	$(CC) -o $@ $<

clean:
	rm -f $(TARGET)

.PHONY: all clean
