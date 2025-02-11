include mk/common.mk
include mk/toolchain.mk

OUT ?= build
BIN := $(OUT)/rv32emu

CONFIG_FILE := $(OUT)/.config
-include $(CONFIG_FILE)

CFLAGS = -std=gnu99 -O2 -Wall -Wextra
CFLAGS += -Wno-unused-label
CFLAGS += -include src/common.h

# Set the default stack pointer
CFLAGS += -D DEFAULT_STACK_ADDR=0xFFFFE000
# Set the default args starting address
CFLAGS += -D DEFAULT_ARGS_ADDR=0xFFFFF000

# Enable link-time optimization (LTO)
ENABLE_LTO ?= 1
ifeq ($(call has, LTO), 1)
ifeq ("$(CC_IS_CLANG)$(CC_IS_GCC)",)
$(warning LTO is only supported in clang and gcc.)
override ENABLE_LTO := 0
endif
endif
$(call set-feature, LTO)
ifeq ($(call has, LTO), 1)
ifeq ("$(CC_IS_GCC)", "1")
CFLAGS += -flto
endif
ifeq ("$(CC_IS_CLANG)", "1")
CFLAGS += -flto=thin -fsplit-lto-unit
LDFLAGS += -flto=thin
endif
endif

# Disable Intel's Control-flow Enforcement Technology (CET)
CFLAGS += $(CFLAGS_NO_CET)

OBJS_EXT :=

# Control and Status Register (CSR)
ENABLE_Zicsr ?= 1
$(call set-feature, Zicsr)

# Instruction-Fetch Fence
ENABLE_Zifencei ?= 1
$(call set-feature, Zifencei)

# Integer Multiplication and Division instructions
ENABLE_EXT_M ?= 1
$(call set-feature, EXT_M)

# Atomic Instructions
ENABLE_EXT_A ?= 1
$(call set-feature, EXT_A)

# Compressed extension instructions
ENABLE_EXT_C ?= 1
$(call set-feature, EXT_C)

# Single-precision floating point instructions
ENABLE_EXT_F ?= 1
$(call set-feature, EXT_F)
ifeq ($(call has, EXT_F), 1)
SOFTFLOAT_OUT = $(abspath $(OUT)/softfloat)
src/softfloat/build/Linux-RISCV-GCC/Makefile:
	git submodule update --init src/softfloat/
SOFTFLOAT_LIB := $(SOFTFLOAT_OUT)/softfloat.a
$(SOFTFLOAT_LIB): src/softfloat/build/Linux-RISCV-GCC/Makefile
	$(MAKE) -C $(dir $<) BUILD_DIR=$(SOFTFLOAT_OUT)
$(OUT)/decode.o $(OUT)/riscv.o: $(SOFTFLOAT_LIB)
LDFLAGS += $(SOFTFLOAT_LIB)
LDFLAGS += -lm
endif

# Enable adaptive replacement cache policy, default is LRU
ENABLE_ARC ?= 0
$(call set-feature, ARC)

# Experimental SDL oriented system calls
ENABLE_SDL ?= 1
ifeq ($(call has, SDL), 1)
ifeq (, $(shell which sdl2-config))
$(warning No sdl2-config in $$PATH. Check SDL2 installation in advance)
override ENABLE_SDL := 0
endif
ifeq (1, $(shell pkg-config --exists SDL2_mixer; echo $$?))
$(warning No SDL2_mixer lib installed. Check SDL2_mixer installation in advance)
override ENABLE_SDL := 0
endif
endif
$(call set-feature, SDL)
ifeq ($(call has, SDL), 1)
OBJS_EXT += syscall_sdl.o
$(OUT)/syscall_sdl.o: CFLAGS += $(shell sdl2-config --cflags)
LDFLAGS += $(shell sdl2-config --libs) -pthread
LDFLAGS += $(shell pkg-config --libs SDL2_mixer)
endif

ENABLE_GDBSTUB ?= 0
$(call set-feature, GDBSTUB)
ifeq ($(call has, GDBSTUB), 1)
GDBSTUB_OUT = $(abspath $(OUT)/mini-gdbstub)
GDBSTUB_COMM = 127.0.0.1:1234
src/mini-gdbstub/Makefile:
	git submodule update --init $(dir $@)
GDBSTUB_LIB := $(GDBSTUB_OUT)/libgdbstub.a
$(GDBSTUB_LIB): src/mini-gdbstub/Makefile
	$(MAKE) -C $(dir $<) O=$(dir $@)
# FIXME: track gdbstub dependency properly
$(OUT)/decode.o: $(GDBSTUB_LIB)
OBJS_EXT += gdbstub.o breakpoint.o
CFLAGS += -D'GDBSTUB_COMM="$(GDBSTUB_COMM)"'
LDFLAGS += $(GDBSTUB_LIB) -pthread
gdbstub-test: $(BIN)
	$(Q).ci/gdbstub-test.sh && $(call notice, [OK])
endif

# For tail-call elimination, we need a specific set of build flags applied.
# FIXME: On macOS + Apple Silicon, -fno-stack-protector might have a negative impact.
$(OUT)/emulate.o: CFLAGS += -foptimize-sibling-calls -fomit-frame-pointer -fno-stack-check -fno-stack-protector

# Clear the .DEFAULT_GOAL special variable, so that the following turns
# to the first target after .DEFAULT_GOAL is not set.
.DEFAULT_GOAL :=

all: config $(BIN)

OBJS := \
	map.o \
	utils.o \
	decode.o \
	io.o \
	syscall.o \
	emulate.o \
	riscv.o \
	elf.o \
	cache.o \
	mpool.o \
	$(OBJS_EXT) \
	main.o

OBJS := $(addprefix $(OUT)/, $(OBJS))
deps := $(OBJS:%.o=%.o.d)

$(OUT)/%.o: src/%.c
	$(VECHO) "  CC\t$@\n"
	$(Q)$(CC) -o $@ $(CFLAGS) -c -MMD -MF $@.d $<

$(BIN): $(OBJS)
	$(VECHO) "  LD\t$@\n"
	$(Q)$(CC) -o $@ $^ $(LDFLAGS)

config: $(CONFIG_FILE)
$(CONFIG_FILE):
	$(Q)echo "$(CFLAGS)" | xargs -n1 | sort | sed -n 's/^RV32_FEATURE/ENABLE/p' > $@
	$(VECHO) "Check the file $(OUT)/.config for configured items.\n"

# Tools
include mk/tools.mk
tool: $(TOOLS_BIN)

# RISC-V Architecture Tests
include mk/riscv-arch-test.mk
include mk/tests.mk

CHECK_ELF_FILES := \
	hello \
	puzzle \

ifeq ($(call has, EXT_M), 1)
CHECK_ELF_FILES += \
	pi
endif

EXPECTED_hello = Hello World!
EXPECTED_puzzle = success in 2005 trials
EXPECTED_pi = 3.141592653589793238462643383279502884197169399375105820974944592307816406286208998628034825342117067982148086

check: $(BIN)
	$(Q)$(foreach e,$(CHECK_ELF_FILES),\
	    $(PRINTF) "Running $(e).elf ... "; \
	    if [ "$(shell $(BIN) $(OUT)/$(e).elf | uniq)" = "$(strip $(EXPECTED_$(e))) inferior exit code 0" ]; then \
	    $(call notice, [OK]); \
	    else \
	    $(PRINTF) "Failed.\n"; \
	    exit 1; \
	    fi; \
	)

EXPECTED_aes_sha1 = 1242a6757c8aef23e50b5264f5941a2f4b4a347e  -
misalign: $(BIN)
	$(Q)$(PRINTF) "Running aes.elf ... "; 
	$(Q)if [ "$(shell $(BIN) -m $(OUT)/aes.elf | $(SHA1SUM))" = "$(EXPECTED_aes_sha1)" ]; then \
	    $(call notice, [OK]); \
	    else \
	    $(PRINTF) "Failed.\n"; \
	    fi

include mk/external.mk

# Non-trivial demonstration programs
ifeq ($(call has, SDL), 1)
doom: $(BIN) $(DOOM_DATA)
	(cd $(OUT); ../$(BIN) doom.elf)
ifeq ($(call has, EXT_F), 1)
quake: $(BIN) $(QUAKE_DATA)
	(cd $(OUT); ../$(BIN) quake.elf)
endif
endif

clean:
	$(RM) $(BIN) $(OBJS) $(HIST_BIN) $(HIST_OBJS) $(deps) $(CACHE_OUT)
distclean: clean
	-$(RM) $(DOOM_DATA) $(QUAKE_DATA)
	$(RM) -r $(OUT)/id1
	$(RM) *.zip
	$(RM) -r $(OUT)/mini-gdbstub
	-$(RM) $(OUT)/.config
	-$(RM) -r $(OUT)/softfloat

-include $(deps)
