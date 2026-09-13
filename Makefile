BEND ?= bend
BINARY ?= tar
TWIN ?= tar-c

all: $(BINARY)

$(BINARY): tar.bend effs/words_read.c effs/words_write.c
	$(BEND) tar.bend -o $(BINARY)

$(TWIN): tar.c
	cc -O2 tar.c -o $(TWIN)

check:
	$(BEND) tar.bend

smoke: $(BINARY) $(TWIN)
	rm -rf smoke && mkdir smoke && printf 'hello tar\n' > smoke/a.txt && head -c 5000 /dev/urandom > smoke/b.bin
	cd smoke && TAR_ARGS="-czf out.tgz a.txt b.bin" ../$(BINARY) && ../$(TWIN) -czf twin.tgz a.txt b.bin && cmp out.tgz twin.tgz
	cd smoke && TAR_ARGS="-tzf out.tgz" ../$(BINARY)
	cd smoke && mkdir x && cd x && TAR_ARGS="-xzf ../out.tgz" ../../$(BINARY) && cmp a.txt ../a.txt && cmp b.bin ../b.bin
	rm -rf smoke

clean:
	$(RM) $(BINARY) $(BINARY).c $(TWIN)
	rm -rf smoke

.PHONY: all check smoke clean
