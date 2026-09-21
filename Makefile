BEND ?= bend
BINARY ?= tar
TWIN ?= tar-c
EFFECTS := $(wildcard effs/*.c effs/*.js)

all: $(BINARY)

$(BINARY): tar.bend $(EFFECTS)
	$(BEND) tar.bend -o $(BINARY)

$(TWIN): tar.c
	cc -O2 tar.c -o $(TWIN)

check:
	$(BEND) tar.bend

smoke: $(BINARY) $(TWIN)
	rm -rf smoke && mkdir smoke && printf 'hello tar\n' > smoke/a.txt && head -c 5000 /dev/urandom > smoke/b.bin
	cd smoke && TAR_ARGS="-cf out.tar a.txt b.bin" ../$(BINARY) && ../$(TWIN) -cf twin.tar a.txt b.bin && cmp out.tar twin.tar
	cd smoke && TAR_ARGS="-czf out.tgz a.txt b.bin" ../$(BINARY) && ../$(TWIN) -czf twin.tgz a.txt b.bin && cmp out.tgz twin.tgz
	cd smoke && TAR_ARGS="-czf - a.txt b.bin" ../$(BINARY) > stream.tgz && cmp stream.tgz twin.tgz
	cd smoke && TAR_ARGS="-tzf out.tgz" ../$(BINARY)
	cd smoke && mkdir x && cd x && TAR_ARGS="-xzf ../out.tgz" ../../$(BINARY) && cmp a.txt ../a.txt && cmp b.bin ../b.bin
	rm -rf smoke

clean:
	$(RM) $(BINARY) $(TWIN)
	rm -rf smoke

.PHONY: all check smoke clean
