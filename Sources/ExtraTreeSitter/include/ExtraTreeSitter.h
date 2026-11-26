#ifndef DAWNMARK_EXTRA_TREE_SITTER_H
#define DAWNMARK_EXTRA_TREE_SITTER_H

typedef struct TSLanguage TSLanguage;

const TSLanguage *tree_sitter_c_sharp(void);
const TSLanguage *tree_sitter_dart(void);
const TSLanguage *tree_sitter_fish(void);
const TSLanguage *tree_sitter_kotlin(void);
const TSLanguage *tree_sitter_make(void);
const TSLanguage *tree_sitter_powershell(void);
const TSLanguage *tree_sitter_sql(void);
const TSLanguage *tree_sitter_systemverilog(void);
const TSLanguage *tree_sitter_vhdl(void);

#endif