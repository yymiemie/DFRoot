obj-m += dfroot.o

KDIR ?= /lib/modules/$(shell uname -r)/build
LLVM ?= 1

CFLAGS_dfroot.o := -Os -Qn -fno-addrsig -fno-asynchronous-unwind-tables \
                   -fno-unwind-tables

# dfroot.c guards its 5.4-specific code (__nocfi fallback + the __cfi_check
# shim) with DFROOT_KO_5_4, so it must reach the C preprocessor. It can be
# passed as a make variable (DFROOT_KO_5_4=1) or detected from the kernel
# tree's UTS_RELEASE; without this the #ifdef blocks stay empty and the build
# fails with "unknown type name '__nocfi'".
UTS_REL := $(shell sed -n 's/^#define UTS_RELEASE "\(.*\)"$$/\1/p' \
                    $(KDIR)/include/generated/utsrelease.h 2>/dev/null)
DFROOT_54 :=
ifeq ($(DFROOT_KO_5_4),1)
DFROOT_54 := 1
else ifneq ($(filter 5.4.%,$(UTS_REL)),)
DFROOT_54 := 1
endif
ifneq ($(DFROOT_54),)
CFLAGS_dfroot.o += -DDFROOT_KO_5_4=1
endif

# The 5.4 kernel looks up mod->cfi_check by symbol name ("__cfi_check"), so the
# shim added in dfroot.c must survive stripping. --strip-unneeded would drop it
# (it is not referenced by any relocation), so keep the symbol table instead.
ifeq ($(DFROOT_KO_5_4),1)
STRIP_OPT := --strip-debug
else
STRIP_OPT := --strip-unneeded
endif

all:
	$(MAKE) -C $(KDIR) M=$(CURDIR) \
		ARCH=arm64 \
		LLVM=$(LLVM) \
		modules
	$(OBJCOPY) $(STRIP_OPT) \
	           -R .comment -R .note.gnu.property \
	           -R .note.Linux -R .note.GNU-stack \
	           -R .BTF -R .BTF.base -R .llvm_addrsig \
	           -R .hyp.text -R .hyp.bss -R .hyp.rodata -R .hyp.event_ids \
	           -R .hyp.patchable_function_entries -R .hyp.data \
	           dfroot.ko
	@echo "dfroot.ko symbols:"; $(NM) dfroot.ko 2>/dev/null | grep -E ' __cfi_check$' \
	    || echo "  (no __cfi_check)"

clean:
	$(MAKE) -C $(KDIR) M=$(CURDIR) \
		ARCH=arm64 \
		LLVM=1 \
		clean
	rm -f dfroot.lds

.PHONY: all clean
