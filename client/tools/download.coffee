import {defineTool} from './defineTool'
import {currentBoard, currentPage, currentRoom} from '../AppState'
import dom from '../lib/dom'

browserImport = new Function 'url', 'return import(url)'

fontsData =
  '':
    name: 'Roboto Slab'
    style: 'normal'
    weight: 'normal'
    url: 'https://cdn.jsdelivr.net/gh/googlefonts/robotoslab/fonts/ttf/RobotoSlab-Regular.ttf'
    # url: 'https://cdn.jsdelivr.net/npm/roboto-slab-fontface-kit@1.0.2/fonts/Regular/RobotoSlab-Regular.ttf'
  'strong':
    name: 'Roboto Slab'
    style: 'normal'
    weight: 'strong'
    url: 'https://cdn.jsdelivr.net/gh/googlefonts/robotoslab/fonts/ttf/RobotoSlab-Bold.ttf'
    # url: 'https://cdn.jsdelivr.net/npm/roboto-slab-fontface-kit@1.0.2/fonts/Bold/RobotoSlab-Bold.ttf'
  'code':
    name: 'Roboto Mono'
    style: 'normal'
    weight: 'normal'
    url: 'https://cdn.jsdelivr.net/gh/googlefonts/RobotoMono/fonts/ttf/RobotoMono-Regular.ttf'

export downloadFile = (data, contentType, filename) ->
  download = document.getElementById 'download'
  download.href = URL.createObjectURL new Blob [data], type: contentType
  download.download = filename
  download.click()

## Make SVG file as well as we can synchronously (e.g. for clipboard),
## which doesn't inline images.
export makeSVGSync = ->
  board = currentBoard()
  grid = currentPage()?.grid
  ## Temporarily remove transform for export
  root = board.root # <g>
  oldTransform = root.getAttribute 'transform'
  root.removeAttribute 'transform'
  ## Choose elements to export
  if board.selection.nonempty()
    elts = board.selectedRenderedChildren()
  else
    elts = board.renderedChildren()
  ## Compute bounding box using SVG's getBBox() and getCTM()
  bbox = board.renderedBBox elts
  ## Add used arrowhead markers
  prepend = []
  arrows = new Set
  for elt in elts
    if elt.tagName == 'g'  # pen group may have markers in children
      subelts = elt.childNodes
    else
      subelts = [elt]
    for subelt in subelts
      for attribute in ['marker-start', 'marker-end']
        if (marker = subelt.getAttribute attribute)
          match = marker.match /^url\(#(.+)\)$/
          if match?
            arrowId = match[1]
            unless arrows.has arrowId
              arrows.add arrowId
              prepend.push document.getElementById arrowId
          else
            console.warn "Unrecognized #{attribute}: #{marker}"
  ## Temporarily make grid span entire drawing
  if grid?
    grid.update bbox
    prepend.push grid.grid
  elts[0...0] = prepend
  ## Convert everything to SVG
  svg = (elt.outerHTML for elt in elts).join '\n'
  .replace /&nbsp;/g, '\u00a0' # SVG doesn't support &nbsp;
  .replace /\bdata-tex="([^"]*)"/g, (match, tex) ->
    ## HTML doesn't escape < in attribute values, but XML needs it
    ## (allowing only > to be unescaped)
    "data-tex=\"#{tex
    .replace /</g, '&lt;'
    .replace />/g, '&gt;'
    }\""
  ## Compress using SVG's self-closing tags
  .replace ///(<(\w+)\b[^<>]*)> </\2>///g, '$1/>'
  ## Remove selection-helping rect.bbox elements from text objects
  .replace ///<rect [^<>]* class="bbox" [^<>]*/>///g, ''
  ## Reset transform and grid
  root.setAttribute 'transform', oldTransform if oldTransform?
  grid?.update()
  ## Create SVG header
  fonts = []
  if /<text/.test svg
    fonts.push 'text { font-family: "Roboto Slab", serif }'
    if (useMono = /<[^<>]*class=['"][^'"]*code/.test svg)
      fonts.push 'tspan.code { font-family: "Roboto Mono", monospace }'
    if (useItalic = /<[^<>]*class=['"][^'"]*emph/.test svg)
      fonts.push 'tspan.emph { font-style: oblique }'
    if (useBold = /<[^<>]*class=['"][^'"]*strong/.test svg)
      fonts.push 'tspan.strong { font-weight: bold }'
    if (useStrike = /<[^<>]*class=['"][^'"]*strike/.test svg)
      fonts.push 'tspan.strike { text-decoration: line-through }'
    for styleSheet in document.styleSheets
      if /fonts/.test styleSheet.href
        for rule in styleSheet.rules
          font = rule.cssText
          continue unless useMono or not /Roboto Mono/.test font
          continue unless useBold or not /font-weight:\s*900/.test font
          if (match = font.match /unicode-range:([^;}]*)/)?
            regexp = match[1]
            .replace /(u\+|-)([0-9a-f]{1,4})/ig, (m, prefix, hex) =>
              prefix = '' unless prefix == '-'
              "#{prefix}\\u#{hex.padStart 4, '0'}"
            .replace /[,\s]/g, ''
            regexp = "[#{regexp}]"
            continue unless (new RegExp regexp).test svg
          fonts.push font
    fonts.push ''
  """
    <?xml version="1.0" encoding="utf-8"?>
    <svg xmlns="#{dom.SVGNS}" xmlns:xlink="http://www.w3.org/1999/xlink" viewBox="#{bbox.minX} #{bbox.minY} #{bbox.width()} #{bbox.height()}" width="#{bbox.width()}px" height="#{bbox.height()}px">
    <style>
    .pen line { stroke-linecap: round }
    .pen polyline { stroke-linecap: round; stroke-linejoin: round; fill: none }
    .grid { stroke-width: 0.96; stroke: #c4e3f4 }
    #{fonts.join '\n'}</style>
    #{svg}
    </svg>
  """

## Also inlines images, but asynchronous.
export makeSVG = (options) ->
  svg = makeSVGSync()
  ## Inline images.  (Asynchronous String.replace based on
  ## https://github.com/dsblv/string-replace-async)
  fetches = []
  svg.replace ///<image\b([^<>]*)>///g, (match, attrs) ->
    href = ///href="(https?://[^"]*)"///.exec attrs # ignore data: URLs
    crossorigin = ///crossorigin="([^"]*)"///.exec attrs
    if href? and crossorigin?
      href = href[1]
      crossorigin = crossorigin[1]
      fetches.push [href,
        cache: 'force-cache'
        credentials:
          if crossorigin == 'use-credentials'
            'include'
          else
            'same-origin'
      ]
    else
      fetches.push undefined
  images =
    for args in fetches
      if args?
        try
          response = await fetch ...args
          if response.status == 200
            blob = await response.blob()
            await new Promise (done) ->
              reader = new FileReader
              reader.onloadend = -> done reader.result
              reader.readAsDataURL blob
        catch e
          console.log "Failed to inline image #{args[0]}: #{e}"
  if options?.imageSize
    sizes =
      for image in images
        img = new Image()
        img.src = image
        await img.decode()
        width: img.width
        height: img.height
  count = 0
  svg = svg.replace ///<image\b[^<>]*>///g, (match) ->
    image = images[count]
    size = sizes[count]
    count++
    match = match.replace /<image/, """
      <image width="#{size.width}" height="#{size.height}"
    """ if size
    match
    .replace ///crossorigin="([^"]*)"///, ''
    .replace ///href="([^"]*)"///, (href, url) ->
      "xlink:href=\"#{image ? url}\""
  svg

defineTool
  name: 'downloadSVG'
  category: 'download'
  icon: 'download-svg'
  help: 'Download/export selection or entire drawing as an SVG file'
  click: ->
    svg = await makeSVG()
    downloadFile svg, 'image/svg+xml', "cocreate-#{currentRoom().id}.svg"

defineTool
  name: 'downloadPDF'
  category: 'download'
  icon: 'download-pdf'
  help: 'Download/export selection or entire drawing as a PDF file'
  click: ->
    svg = await makeSVG imageSize: true
    match = /<svg[^<>]*width="([\d\-\.]+)px" height="([\d\-\.]+)px"/.exec svg
    unless match?
      return console.error 'Internal SVG parsing error'
    width = parseFloat match[1]
    height = parseFloat match[2]
    [{jsPDF}, {svg2pdf}] = await Promise.all [
      if Meteor.settings.public?.jspdf
        browserImport Meteor.settings.public.jspdf
      else
        import('jspdf')
    ,
      if Meteor.settings.public?['svg2pdf.js']
        browserImport Meteor.settings.public['svg2pdf.js']
      else
        import('svg2pdf.js')
    ]
    pdf = new jsPDF
      format: [width, height]
      unit: 'pt'
      orientation:
        if width > height
          'landscape'
        else
          'portrait'
    if /<text/.test svg
      for className, fontData of fontsData
        continue if className and
          not svg.includes """<tspan class="#{className}">"""
        font = await fetch fontData.url
        font = await font.blob()
        reader = new FileReader
        reader.readAsDataURL font
        await new Promise (done) -> reader.onload = done
        font = reader.result
        .replace /^data:[^;]*;base64,/, ''
        filename = fontData.url.replace /^.*\//, ''
        pdf.addFileToVFS filename, font
        pdf.addFont filename, fontData.name, fontData.style, fontData.weight
    container = document.createElement 'div'
    container.innerHTML = svg
    ## For debugging:
    #document.body.appendChild container
    await svg2pdf container.firstElementChild, pdf, {width, height}
    pdf.save "cocreate-#{currentRoom().id}.pdf"
