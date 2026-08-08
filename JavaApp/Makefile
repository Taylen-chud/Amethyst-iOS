SHELL := /bin/bash
.SHELLFLAGS = -ec

# Prerequisite variables
SOURCEDIR := src
OUTPUTDIR := build

SOURCES := $(shell find $(SOURCEDIR) -type f -name '*.java')
CLASSES := $(SOURCES:$(SOURCEDIR)/%.java=$(OUTPUTDIR)/%.class)

TARGETS := $(shell find $(SOURCEDIR) -mindepth 1 -maxdepth 1 -type d)
TARGETS := $(filter-out $(OUTPUTDIR)/lwjgl.jar,$(TARGETS:$(SOURCEDIR)/%=$(OUTPUTDIR)/%.jar))

# Add all jars to classpath and allow compiling with private API
JCFLAGS := -cp "$(subst $() $(),:,$(wildcard $(SOURCEDIR)/*/):$(wildcard libs/*/*.jar))" \
           -XDignore.symbol.file \
           -implicit:none

all: $(TARGETS) $(OUTPUTDIR)/lwjgl-3.3.3.jar $(OUTPUTDIR)/lwjgl-3.4.1.jar

# Sometimes the CI produces empty class file resulting in broken jar, so we check and abort here
check_empty_classes:
	@set -e
	@echo "Checking for empty class files"
	$(eval EMPTY_CLASSES := $(shell find $(OUTPUTDIR) -name '*.class' -size 0))
	@if [ -n "$(EMPTY_CLASSES)" ]; then \
		echo "Error: found empty class files in $@: $(EMPTY_CLASSES)"; \
		exit 1; \
	fi

# Rules for building java class
$(CLASSES): $(OUTPUTDIR)/%.class: $(SOURCEDIR)/%.java
	@set -e
	$(eval TARGET=$(word 2, $(subst /, ,$@)))
	@mkdir -p $(OUTPUTDIR)/classes
	@mkdir -p $(dir $@)
	@echo "Compiling $<"
	@$(BOOTJDK)/javac $(JCFLAGS) -d $(OUTPUTDIR)/classes $<
	# Copy the main class and any inner-class files produced by javac into the target dir.
	# No error suppression here on purpose: with -implicit:none above, javac only ever
	# writes exactly the class(es) for $<, so a missing/failed copy here means something
	# is genuinely wrong and should fail the build immediately - this is what launcher.jar
	# (and PojavClassLoader specifically) depends on, and a silently-swallowed failure here
	# is exactly what produced a jar that built "successfully" but was missing a class at
	# runtime.
	@set -e; \
	CLASSNAME=$$(basename "$<" .java); \
	find $(OUTPUTDIR)/classes -name "$$CLASSNAME*.class" -exec cp {} $(dir $@) \;

$(OUTPUTDIR)/launcher.jar: $(CLASSES) check_empty_classes
	@set -e
	@echo "Creating $@"
	@$(BOOTJDK)/jar -cf $@ -C $(basename $@) .

$(OUTPUTDIR)/patchsvc.jar: $(CLASSES)
	@set -e
	# Ensure staging directory exists
	@mkdir -p $(basename $@)
	# Ensure package directories exist under staging dir
	@mkdir -p $(basename $@)/de/maxhenkel
	@mkdir -p $(basename $@)/de/maxhenkel/lame4j
	@mkdir -p $(basename $@)/de/maxhenkel/opus4j
	@mkdir -p $(basename $@)/de/maxhenkel/rnnoise4j
	@mkdir -p $(basename $@)/de/maxhenkel/speex4j
	# Copy compiled classes for de/maxhenkel into the staging dir. No error
	# suppression: if these are missing, the jar would silently ship broken.
	@cp -R $(OUTPUTDIR)/classes/de/maxhenkel/* $(basename $@)/de/maxhenkel/
	# Now perform the patch renames.
	@mv $(basename $@)/de/maxhenkel/lame4j/Mp3Decoder.class $(basename $@)/de/maxhenkel/lame4j/Mp3Decoder.class.patch
	@mv $(basename $@)/de/maxhenkel/lame4j/Mp3Encoder.class $(basename $@)/de/maxhenkel/lame4j/Mp3Encoder.class.patch
	@mv $(basename $@)/de/maxhenkel/opus4j/OpusDecoder.class $(basename $@)/de/maxhenkel/opus4j/OpusDecoder.class.patch
	@mv $(basename $@)/de/maxhenkel/opus4j/OpusEncoder.class $(basename $@)/de/maxhenkel/opus4j/OpusEncoder.class.patch
	@mv $(basename $@)/de/maxhenkel/rnnoise4j/Denoiser.class $(basename $@)/de/maxhenkel/rnnoise4j/Denoiser.class.patch
	@mv $(basename $@)/de/maxhenkel/speex4j/AutomaticGainControl.class $(basename $@)/de/maxhenkel/speex4j/AutomaticGainControl.class.patch
	@rm -rf $(basename $@)/de/maxhenkel/*/*.class
	@echo "Creating $@"
	@$(BOOTJDK)/jar -cfm $@ $(SOURCEDIR)/patchsvc.txt -C $(basename $@) .

$(OUTPUTDIR)/lwjgl-3.3.3.jar: $(CLASSES) check_empty_classes
	@set -e
	@echo "Creating $@"
	@mkdir -p $(OUTPUTDIR)/lwjgl_lib_3.3.3
	@cd $(OUTPUTDIR)/lwjgl_lib_3.3.3 && find ../../libs/lwjgl-3.3.3 -name 'lwjgl*.jar' -exec $(BOOTJDK)/jar -xf {} \;
	@rm -rf $(OUTPUTDIR)/lwjgl_lib_3.3.3/META-INF
	@cp -R $(OUTPUTDIR)/lwjgl/. $(OUTPUTDIR)/lwjgl_lib_3.3.3/
	@$(BOOTJDK)/jar -cf $@ -C $(OUTPUTDIR)/lwjgl_lib_3.3.3 .

$(OUTPUTDIR)/lwjgl-3.4.1.jar: $(CLASSES) check_empty_classes
	@set -e
	@echo "Creating $@"
	@mkdir -p $(OUTPUTDIR)/lwjgl_lib_3.4.1
	@cd $(OUTPUTDIR)/lwjgl_lib_3.4.1 && find ../../libs/lwjgl-3.4.1 -name 'lwjgl*.jar' -exec $(BOOTJDK)/jar -xf {} \;
	@rm -rf $(OUTPUTDIR)/lwjgl_lib_3.4.1/META-INF
	@cp -R $(OUTPUTDIR)/lwjgl/. $(OUTPUTDIR)/lwjgl_lib_3.4.1/
	@$(BOOTJDK)/jar -cf $@ -C $(OUTPUTDIR)/lwjgl_lib_3.4.1 .

$(OUTPUTDIR)/patchjna_agent.jar: $(CLASSES)
	@set -e
	@mkdir -p $(basename $@)
	@mkdir -p $(basename $@)/com/sun/jna
	# Copy compiled classes for com/sun/jna into the staging dir. No error
	# suppression: if this is missing, the jar would silently ship broken.
	@cp -R $(OUTPUTDIR)/classes/com/sun/jna/* $(basename $@)/com/sun/jna/
	@mv $(basename $@)/com/sun/jna/Platform.class $(basename $@)/com/sun/jna/Platform.class.patch
	@echo "Creating $@"
	@$(BOOTJDK)/jar -cfm $@ $(SOURCEDIR)/patchjna_agent.txt -C $(basename $@) .

clean:
	rm -rf $(OUTPUTDIR)

.SUFFIXES: .java
.PHONY: all clean
