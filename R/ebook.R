#' The EPUB e-book format
#'
#' Convert a book to the EPUB format, which is is an e-book format supported by
#' many readers, such as Amazon Kindle Fire and iBooks on Apple devices.
#' @inheritParams html_document2
#' @param fig_width,fig_height,dev,fig_caption Figure options (width, height,
#'   the graphical device, and whether to render figure captions).
#' @param number_sections Whether to number sections.
#' @param toc,toc_depth Whether to generate a table of contents, and its depth.
#' @param stylesheet A character vector of paths to CSS stylesheets to be
#'   applied to the eBook.
#' @param cover_image The path to a cover image.
#' @param metadata The path to the EPUB metadata file.
#' @param chapter_level The level by which the e-book is split into separate
#'   \dQuote{chapter} files.
#' @param epub_version Whether to use version 3 or 2 of EPUB. This correspond to
#'   [Pandoc's supported output
#'   format](https://pandoc.org/MANUAL.html#option--to). `"epub"` is an alias
#'   for `"epub3"` since Pandoc 2.0 and `"epub2"` for earlier version.
#' @param md_extensions A character string of Pandoc Markdown extensions.
#' @param pandoc_args A vector of additional Pandoc arguments.
#' @param template Pandoc template to use for rendering. Pass `"default"`
#'   to use Pandoc's built-in template; pass a path to use a custom template.
#'   The default pandoc template should be sufficient for most use cases. In
#'   case you want to develop a custom template, we highly recommend to start
#'   from the default EPUB templates at
#'   <https://github.com/jgm/pandoc-templates/>.
#' @note Figure/table numbers cannot be generated if sections are not numbered
#'   (`number_sections = FALSE`).
#' @md
#' @export
epub_book = function(
  fig_width = 5, fig_height = 4, dev = 'png', fig_caption = TRUE,
  number_sections = TRUE, toc = FALSE, toc_depth = 3, stylesheet = NULL,
  cover_image = NULL, metadata = NULL, chapter_level = 1,
  epub_version = c('epub3', 'epub', 'epub2'), md_extensions = NULL,
  global_numbering = !number_sections, pandoc_args = NULL,
  template = 'default'
) {
  epub_version = match.arg(epub_version)
  args = c(
    pandoc_args,
    if (number_sections) '--number-sections',
    if (toc) '--toc',
    if (!missing(toc_depth)) c('--toc-depth', toc_depth),
    if (!is.null(cover_image)) c('--epub-cover-image', cover_image),
    if (!is.null(metadata)) c('--epub-metadata', metadata),
    if (!identical(template, 'default')) c('--template', template),
    if (!missing(chapter_level)) c('--epub-chapter-level', chapter_level)
  )
  if (is.null(stylesheet)) css = NULL else {
    css = rmarkdown::pandoc_path_arg(epub_css(stylesheet))
    args = c(args, if (pandoc2.0()) '--css' else '--epub-stylesheet', css)
  }

  from = rmarkdown::from_rmarkdown(fig_caption, md_extensions)

  config = rmarkdown::output_format(
    knitr = rmarkdown::knitr_options_html(fig_width, fig_height, NULL, FALSE, dev),
    pandoc = rmarkdown::pandoc_options(epub_version, from, args, ext = '.epub'),
    pre_processor = function(metadata, input_file, runtime, knit_meta, files_dir, output_dir) {
      process_markdown(input_file, from, args, global_numbering)
      NULL
    },
    post_processor = function(metadata, input, output, clean, verbose) {
      if (length(css)) file.remove(css)
      move_output(output)
    }
  )
  config = common_format_config(config, 'epub')
  config
}

move_output = function(output) {
  if (is.null(opts$get('output_dir'))) return(output)
  output2 = output_path(output)
  file.rename(output, output2)
  output2
}

process_markdown = function(
  input_file, from, pandoc_args, global, to_md = output_md(),
  content = read_utf8(input_file), output = input_file
) {
  intermediate_html = with_ext(input_file, 'tmp.html')
  on.exit(file.remove(intermediate_html), add = TRUE)
  rmarkdown::pandoc_convert(
    input_file, 'html', from, intermediate_html, TRUE,
    c(pandoc_args, '--section-divs', '--mathjax', '--number-sections')
  )
  x = read_utf8(intermediate_html)
  x = clean_html_tags(x)
  figs = parse_fig_labels(x, global)
  # resolve cross-references and update the Markdown input file
  i = xfun::prose_index(content)
  content[i] = resolve_refs_md(content[i], c(figs$ref_table, parse_section_labels(x)), to_md)
  if (to_md) content = gsub(
    '^\\\\BeginKnitrBlock\\{[^}]+\\}|\\\\EndKnitrBlock\\{[^}]+\\}$', '', content
  )
  content = resolve_ref_links_epub(
    content, parse_ref_links(x, '^<p>%s (.+)</p>$'), to_md
  )
  if (!to_md) {
    i = xfun::prose_index(content)
    s = content[i]
    s = restore_part_epub(s)
    s = restore_appendix_epub(s)
    s = protect_math_env(s)
    content[i] = s
  }
  if (is.null(output)) content else write_utf8(content, output)
}

resolve_refs_md = function(content, ref_table, to_md = output_md()) {
  ids = names(ref_table)
  # replace (\#fig:label) with Figure x.x:
  for (i in grep('^(<p class="caption|<caption>|Table:|\\\\BeginKnitrBlock)|(!\\[.*?\\]\\(.+?\\))', content)) {
    for (j in ids) {
      m = sprintf('\\(\\\\#%s\\)', j)
      if (grepl(m, content[i])) {
        id = ''; sep = ':'
        type = gsub('^([^:]+).*$', '\\1', j)
        if (type %in% theorem_abbr) {
          id = sprintf('<span id="%s"></span>', j)
          sep = ''
        }
        label = label_prefix(type, sep = sep)(ref_table[j])
        content[i] = sub(m, paste0(id, label, ' '), content[i])
        break
      }
    }
  }
  # remove labels in figure alt text (it will contain \ like (\#fig:label))
  content = gsub('"\\(\\\\#(fig:[-[:alnum:]]+)\\)', '"', content)
  # replace (\#eq:label) with equation numbers
  content = add_eq_numbers(content, ids, ref_table, to_md)

  # look for \@ref(label) and resolve to actual figure/table/section numbers
  m = gregexpr('(?<!`)\\\\@ref\\(([-:[:alnum:]]+)\\)', content, perl = TRUE)
  refs = regmatches(content, m)
  regmatches(content, m) = lapply(refs, ref_to_number, ref_table, TRUE)
  content
}

# change labels (\#eq:label) in math environments into actual numbers in \tag{}
add_eq_numbers = function(x, ids, ref_table, to_md = output_md()) {
  ids = grep('^eq:', ids, value = TRUE)
  if (length(ids) == 0) return(x)
  ref_table = ref_table[ids]
  env = paste(math_envs, collapse = '|')
  # no white spaces allowed after \begin|end{env}, and I added spaces for those
  # env in verbatim chunks so so they won't be recognized and I can display
  i1 = grep(sprintf('^\\\\begin\\{(%s)\\}$', env), x)
  i2 = grep(sprintf('^\\\\end\\{(%s)\\}$', env), x)
  if (length(i1) * length(i2) == 0) return(x)
  i3 = unlist(mapply(seq, i1, next_nearest(i1, i2), SIMPLIFY = FALSE))
  i3 = i3[grep('\\(\\\\(#eq:[-/[:alnum:]]+)\\)', x[i3])]
  for (i in i3) {
    for (j in ids) {
      m = sprintf('\\(\\\\#%s\\)', j)
      if (grepl(m, x[i])) {
        # it is weird that \tag{} does not work in iBooks, so I have to cheat by
        # using \qquad then the (equation number); however, when the output
        # format is Markdown instead of EPUB, I'll still use \tag{}
        x[i] = sub(m, sprintf(
          if (to_md) '\\\\tag{%s}' else '\\\\qquad(%s)', ref_table[j]
        ), x[i])
        break
      }
    }
  }
  x
}

# replace text references (ref:label); note refs is the parsed text references
# from the HTML output of Markdown, i.e. Markdown has been translated to HTML
resolve_ref_links_epub = function(x, refs, to_md = output_md()) {
  res = parse_ref_links(x, '^%s (.+[^ ])$')
  if (is.null(res)) return(x)
  if (to_md && length(refs$tags)) {
    i = match(res$tags, refs$tags)
    res$txts[!is.na(i)] = na.omit(refs$txts[i])
  }
  restore_ref_links(res$content, '(?<!`)%s', res$tags, res$txts, TRUE)
}

reg_part = '^# \\(PART(\\\\\\*)?\\) .+ \\{-\\}$'

# simply remove parts in epub
restore_part_epub = function(x) {
  x[grep(reg_part, x)] = ''
  x
}

reg_app = '^(# )\\(APPENDIX\\) (.+ \\{-\\})$'
# this is not good enough since appendix chapters will continue to be numbered
# after the last chapter instead of being numbered differently like A.1, A.2,
# ..., but probably not too many people care about it in e-books
restore_appendix_epub = function(x) {
  i = find_appendix_line(reg_app, x)
  if (length(i) == 0) return(x)
  x[i] = gsub(reg_app, '\\1\\2', x[i])
  x
}

# may add more LaTeX environments later
math_envs = c('equation', 'align', 'eqnarray', 'gather')

# wrap math environments in $$, otherwise they are discarded by Pandoc
# https://github.com/jgm/pandoc/issues/2758
protect_math_env = function(x) {
  env = c(math_envs, paste0(math_envs, '*'))
  s1 = sprintf('\\begin{%s}', env)
  s2 = sprintf('\\end{%s}', env)
  for (s in s1) {
    i = x == s
    x[i] = paste0('$$', x[i])
  }
  for (s in s2) {
    i = x == s
    x[i] = paste0(x[i], '$$')
  }
  x
}

# manually base64 encode images in css: https://github.com/jgm/pandoc/issues/2733
epub_css = function(files, output = tempfile('epub', fileext = '.css')) {
  css = unlist(lapply(files, function(css) {
    in_dir(dirname(css), base64_css(basename(css)))
  }))
  write_utf8(css, output)
  output
}

#' A wrapper function to convert e-books using Calibre
#'
#' This function calls the command \command{ebook-convert} in Calibre
#' (\url{https://calibre-ebook.com}) to convert e-books.
#' @param input The input filename.
#' @param output The output filename or extension (if only an extension is
#'   provided, the output filename will be the input filename with its extension
#'   replaced by \code{output}; for example, \code{calibre('foo.epub', 'mobi')}
#'   generates \file{foo.mobi}).
#' @param options A character vector of additional options to be passed to
#'   \command{ebook-convert}.
#' @export
#' @return The output filename.
calibre = function(input, output, options = '') {
  if (!grepl('[.]', output)) output = with_ext(input, output)
  if (input == output) stop('input and output filenames are the same')
  unlink(output)
  system2('ebook-convert', c(shQuote(input), shQuote(output), options))
  if (!file.exists(output)) stop('Failed to convert ', input, ' to ', output)
  invisible(output)
}

# TODO: remove kindlegen() in the future

#' A wrapper function to convert EPUB to the Mobipocket format
#'
#' This function has been deprecated, since Amazon no longer provides KindleGen.
#' Please consider using \code{bookdown::\link{calibre}()} instead if you want
#' \file{.mobi} output.
#' @param epub The path to a \code{.epub} file (e.g. created from the
#'   \code{\link{epub_book}()} format). If missing, it is automatically guessed
#'   from the book configurations.
#' @param exec The path to the executable \command{kindlegen}.
#' @return The path of the \file{.mobi} file if the conversion is successful.
#' @export
#' @keywords internal
kindlegen = function(epub, exec = Sys.which('kindlegen')) {
  warning(
    'Since Amazon no longer provides KindleGen, this function has been deprecated ',
    'and will be removed in a future version of bookdown. Please consider using ',
    'bookdonw::calibre() instead.'
  )
  if (exec == '') stop('Cannot find the executable KindleGen.')
  if (missing(epub)) {
    on.exit(opts$restore(), add = TRUE)
    config = load_config()
    main = with_ext(book_filename(config), 'epub')
    epub = file.path(output_dirname(NULL, config), main)
  }
  if (!file.exists(epub)) stop('The EPUB file ', epub, ' does not exist')
  mobi = with_ext(epub, 'mobi')
  unlink(mobi)
  system2(exec, shQuote(epub))
  if (!file.exists(mobi)) stop('Failed to convert epub to mobi')
  mobi
}
