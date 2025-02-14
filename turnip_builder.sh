#!/bin/bash -e
green='\033[0;32m'
red='\033[0;31m'
nocolor='\033[0m'

deps="meson ninja patchelf unzip curl pip flex bison zip git"
workdir="$(pwd)/turnip_workdir"
packagedir="$workdir/turnip_module"
ndkver="android-ndk-r26c"
sdkver="31"
mesasrc="https://gitlab.freedesktop.org/mesa/mesa.git"

#array of string => commit/branch;patch args
patches=(
	"8gen3-fix;merge_requests/27912;"
	"Mem-leaks-tu-shader;merge_requests/27847;"
	"Fix-undefined-value-gl_ClipDistance;merge_requests/28109;"
	"Visual-fixes-in-some-games;merge_requests/28148;"
)
#patches=()
commit=""
commit_short=""
mesa_version=""
vulkan_version=""
clear

# there are 4 functions here, simply comment to disable.
# you can insert your own function and make a pull request.
run_all(){
	check_deps
	prepare_workdir
	build_lib_for_android
	port_lib_for_adrenotool

	if (( ${#patches[@]} )); then
		prepare_workdir "patched"
		build_lib_for_android
		port_lib_for_adrenotool "patched"
	fi

}

check_deps(){
	sudo apt remove meson
	pip install meson

	echo "Checking system for required Dependencies ..."
	for deps_chk in $deps;
		do
			sleep 0.25
			if command -v "$deps_chk" >/dev/null 2>&1 ; then
				echo -e "$green - $deps_chk found $nocolor"
			else
				echo -e "$red - $deps_chk not found, can't countinue. $nocolor"
				deps_missing=1
			fi;
		done

		if [ "$deps_missing" == "1" ]
			then echo "Please install missing dependencies" && exit 1
		fi

	echo "Installing python Mako dependency (if missing) ..." $'\n'
	pip install mako &> /dev/null
}

prepare_workdir(){
	echo "Creating and entering to work directory ..." $'\n'
	mkdir -p "$workdir" && cd "$_"

	if [ -z "${ANDROID_NDK_LATEST_HOME}" ]; then
		if [ ! -n "$(ls -d android-ndk*)" ]; then
			echo "Downloading android-ndk from google server (~640 MB) ..." $'\n'
			curl https://dl.google.com/android/repository/"$ndkver"-linux.zip --output "$ndkver"-linux.zip &> /dev/null
			###
			echo "Exracting android-ndk to a folder ..." $'\n'
			unzip "$ndkver"-linux.zip  &> /dev/null
		fi
	else	
		echo "Using android ndk from github image"
	fi

	if [ -z "$1" ]; then
		if [ -d mesa ]; then
			echo "Removing old mesa ..." $'\n'
			rm -rf mesa
		fi
		
		echo "Cloning mesa ..." $'\n'
		git clone --depth=1 "$mesasrc"  &> /dev/null

		cd mesa
		commit_short=$(git rev-parse --short HEAD)
		commit=$(git rev-parse HEAD)
		mesa_version=$(cat VERSION | xargs)
		version=$(awk -F'COMPLETE VK_MAKE_API_VERSION(|)' '{print $2}' <<< $(cat include/vulkan/vulkan_core.h) | xargs)
		major=$(echo $version | cut -d "," -f 2 | xargs)
		minor=$(echo $version | cut -d "," -f 3 | xargs)
		patch=$(awk -F'VK_HEADER_VERSION |\n#define' '{print $2}' <<< $(cat include/vulkan/vulkan_core.h) | xargs)
		vulkan_version="$major.$minor.$patch"
	else		
		if [ -z ${experimental_patches+x} ]; then
			echo "No experimental patches found"; 
		else 
			patches=("${experimental_patches[@]}" "${patches[@]}")
		fi

		cd mesa
		for patch in ${patches[@]}; do
			echo "Applying patch $patch"
			patch_source="$(echo $patch | cut -d ";" -f 2 | xargs)"
			if [[ $patch_source == *"../.."* ]]; then
				git apply "$patch_source"
				sleep 1
			else 
				patch_file="${patch_source#*\/}"
				patch_args=$(echo $patch | cut -d ";" -f 3 | xargs)
				curl --output "$patch_file".patch -k --retry-delay 30 --retry 5 -f --retry-all-errors https://gitlab.freedesktop.org/mesa/mesa/-/"$patch_source".patch
				sleep 1
			
				git apply $patch_args "$patch_file".patch
			fi
			
		done
	fi

}

build_lib_for_android(){
	echo "Creating meson cross file ..." $'\n'
	if [ -z "${ANDROID_NDK_LATEST_HOME}" ]; then
		ndk="$workdir/$ndkver/toolchains/llvm/prebuilt/linux-x86_64/bin"
	else	
		ndk="$ANDROID_NDK_LATEST_HOME/toolchains/llvm/prebuilt/linux-x86_64/bin"
	fi

	cat <<EOF >"android-aarch64"
[binaries]
ar = '$ndk/llvm-ar'
c = ['ccache', '$ndk/aarch64-linux-android$sdkver-clang']
cpp = ['ccache', '$ndk/aarch64-linux-android$sdkver-clang++', '-fno-exceptions', '-fno-unwind-tables', '-fno-asynchronous-unwind-tables', '-static-libstdc++']
c_ld = 'lld'
cpp_ld = 'lld'
strip = '$ndk/aarch64-linux-android-strip'
pkgconfig = ['env', 'PKG_CONFIG_LIBDIR=NDKDIR/pkgconfig', '/usr/bin/pkg-config']
[host_machine]
system = 'android'
cpu_family = 'aarch64'
cpu = 'armv8'
endian = 'little'
EOF

	echo "Generating build files ..." $'\n'
	meson build-android-aarch64 --cross-file "$workdir"/mesa/android-aarch64 -Dbuildtype=release -Dplatforms=android -Dplatform-sdk-version=$sdkver -Dandroid-stub=true -Dgallium-drivers= -Dvulkan-drivers=freedreno -Dvulkan-beta=true -Dfreedreno-kmds=kgsl -Db_lto=true &> "$workdir"/meson_log

	echo "Compiling build files ..." $'\n'
	ninja -C build-android-aarch64 &> "$workdir"/ninja_log
}

port_lib_for_adrenotool(){
	echo "Using patchelf to match soname ..."  $'\n'
	cp "$workdir"/mesa/build-android-aarch64/src/freedreno/vulkan/libvulkan_freedreno.so "$workdir"
	cd "$workdir"
	patchelf --set-soname vulkan.adreno.so libvulkan_freedreno.so
	mv libvulkan_freedreno.so vulkan.ad07XX.so

	if ! [ -a vulkan.ad07XX.so ]; then
		echo -e "$red Build failed! $nocolor" && exit 1
	fi

	mkdir -p "$packagedir" && cd "$_"

	date=$(date +'%b %d, %Y')
	patched=""

	if [ ! -z "$1" ]; then
		patched="_patched"
	fi

	cat <<EOF >"meta.json"
{
  "schemaVersion": 1,
  "name": "Turnip - $date - $commit_short$patched",
  "description": "Compiled from Mesa, Commit $commit_short$patched",
  "author": "mesa",
  "packageVersion": "1",
  "vendor": "Mesa",
  "driverVersion": "$mesa_version/vk$vulkan_version",
  "minApi": 27,
  "libraryName": "vulkan.ad07XX.so"
}
EOF

	filename=turnip_"$(date +'%b-%d-%Y')"_"$commit_short"
	echo "Copy necessary files from work directory ..." $'\n'
	cp "$workdir"/vulkan.ad07XX.so "$packagedir"

	echo "Packing files in to adrenotool package ..." $'\n'
	zip -9 "$workdir"/"$filename$patched".zip ./*

	cd "$workdir"
	
	echo "Turnip - $mesa_version - $date" > release
	echo "$mesa_version"_"$commit_short" > tag
	echo  $filename > filename
	echo "### Base commit : [$commit_short](https://gitlab.freedesktop.org/mesa/mesa/-/commit/$commit_short)" > description
	echo "## Upstreams / Patches" >> description
	
	if (( ${#patches[@]} )); then
		echo "These have not been merged by Mesa officially yet and may introduce bugs or" >> description
		echo "we revert stuff that breaks games but still got merged in (see --reverse)" >> description
		for patch in ${patches[@]}; do
			patch_name="$(echo $patch | cut -d ";" -f 1 | xargs)"
			patch_source="$(echo $patch | cut -d ";" -f 2 | xargs)"
			patch_args="$(echo $patch | cut -d ";" -f 3 | xargs)"
			if [[ $patch_source == *"../.."* ]]; then
				echo "- $patch_name, $patch_source, $patch_args" >> description
			else 
				echo "- $patch_name, [$patch_source](https://gitlab.freedesktop.org/mesa/mesa/-/$patch_source), $patch_args" >> description
			fi
		done
		echo "true" > patched
		echo "" >> description
		echo "_Upstreams / Patches are only applied to the patched version (\_patched.zip)_" >> description
	else
		echo "No patch" >> description
		echo "false" > patched
	fi
	
	echo "_If a patch is not present anymore, it's most likely because it got merged, is not needed anymore or was breaking something._" >> description

	if ! [ -a "$workdir"/"$filename".zip ];
		then echo -e "$red-Packing failed!$nocolor" && exit 1
		else echo -e "$green-All done, you can take your zip from this folder;$nocolor" && echo "$workdir"/
	fi
}

run_all
