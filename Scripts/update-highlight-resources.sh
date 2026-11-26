#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
checkouts=${1:-"$root/.build/checkouts"}
destination="$root/Sources/EditorKit/CodeHighlightResources"

mkdir -p "$destination/Queries" "$destination/Licenses"
sync_resource() {
    cmp -s "$1" "$2" || install -m 644 "$1" "$2"
}
sync_grammar() {
    name="tree-sitter-${2:-$1}"
    sync_resource "$checkouts/$name/${3:-queries/highlights.scm}" "$destination/Queries/$1.scm"
    sync_resource "$checkouts/$name/${4:-LICENSE}" "$destination/Licenses/$name.txt"
}
if [ "${1:-}" = "--refresh-vendored" ]; then
    temporary=$(mktemp -d)
    trap 'rm -rf "$temporary"' EXIT

    vendor_grammar() {
        language=$1
        repository=$2
        revision=$3
        name="tree-sitter-$language"
        archive="$temporary/$name.tar.gz"
        extraction="$temporary/$name"
        sources="$root/Sources/ExtraTreeSitter/$language"
        mkdir -p "$extraction" "$sources/tree_sitter"
        curl -fsSL --retry 3 "https://codeload.github.com/$repository/tar.gz/$revision" -o "$archive"
        tar -xzf "$archive" -C "$extraction" --strip-components=1
        for file in "$extraction/src/parser.c" "$extraction/src/scanner.c"; do
            if [ -f "$file" ]; then
                sed -E 's@^#include <(tree_sitter/[^>]+)>@#include "\1"@' "$file" > "$temporary/${file##*/}"
                sync_resource "$temporary/${file##*/}" "$sources/${file##*/}"
            fi
        done
        for file in "$extraction"/src/tree_sitter/*.h; do
            sync_resource "$file" "$sources/tree_sitter/${file##*/}"
        done
        if [ "${4:-}" != "local-query" ]; then
            sync_resource "$extraction/queries/highlights.scm" "$destination/Queries/$language.scm"
        fi
        sync_resource "$extraction/LICENSE" "$destination/Licenses/${repository##*/}.txt"
    }

    vendor_grammar csharp tree-sitter/tree-sitter-c-sharp d4bbe18103c3380c6454085e589d2610938da142
    vendor_grammar dart UserNobody14/tree-sitter-dart 0038280b774b65c1b89ba7fec50624d8baed9fe1
    vendor_grammar fish ram02z/tree-sitter-fish b7f1d682941e0c62dfcd6bf9ef481638351bab16
    vendor_grammar kotlin fwcd/tree-sitter-kotlin d6af96d2e23ef0a8ff5ab512864378cf08fba311
    vendor_grammar make tree-sitter-grammars/tree-sitter-make 70613f3d812cbabbd7f38d104d60a409c4008b43
    vendor_grammar powershell airbus-cert/tree-sitter-powershell 65ea6919e816a7ac142acec7ee72757f89db8439
    vendor_grammar sql DerekStride/tree-sitter-sql 2d088525f3f986108d969dab526a0d7129281e24
    vendor_grammar systemverilog gmlarumbe/tree-sitter-systemverilog 306458a919c0409e0ee53d5bf8731eb69915d7d1
    vendor_grammar vhdl alemuller/tree-sitter-vhdl a3b2d84990527c7f8f4ae219c332c00c33d2d8e5 local-query
else
    for language in bash c cpp css dockerfile go html java javascript json julia objc php python r ruby rust scala swift toml typescript yaml; do
        sync_grammar "$language"
    done
    sync_grammar lua lua queries/highlights.scm LICENSE.md
    sync_grammar matlab matlab queries/helix/highlights.scm
    sync_grammar asm asm queries/asm/highlights.scm
    for name in tree-sitter swift-tree-sitter; do
        sync_resource "$checkouts/$name/LICENSE" "$destination/Licenses/$name.txt"
    done
fi