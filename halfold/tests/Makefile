# HalfoldKit unit tests: make -C halfold/tests (build output in build/, not committed)
B = build
KIT = ../../dm/ios/Sources/Halfold
run: $(B)/t_kit
	$(B)/t_kit
$(B)/t_kit: t_kit.c $(KIT)/hf_kit.c $(KIT)/hf_kit.h | $(B)
	clang -O1 -Wall -Werror -o $@ t_kit.c $(KIT)/hf_kit.c -lm
$(B):
	mkdir -p $(B)
clean:
	rm -rf $(B)
.PHONY: run clean
