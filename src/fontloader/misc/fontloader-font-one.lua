if not modules then modules = { } end modules ['font-one'] = {
    version   = 1.001,
    comment   = "companion to font-ini.mkiv",
    author    = "Hans Hagen, PRAGMA-ADE, Hasselt NL",
    copyright = "PRAGMA ADE / ConTeXt Development Team",
    license   = "see context related readme files"
}

--[[ldx--
<p>Some code may look a bit obscure but this has to do with the fact that we also use
this code for testing and much code evolved in the transition from <l n='tfm'/> to
<l n='afm'/> to <l n='otf'/>.</p>

<p>The following code still has traces of intermediate font support where we handles
font encodings. Eventually font encoding went away but we kept some code around in
other modules.</p>

<p>This version implements a node mode approach so that users can also more easily
add features.</p>
--ldx]]--

local fonts, logs, trackers, containers, resolvers = fonts, logs, trackers, containers, resolvers

local next, type, tonumber, rawget = next, type, tonumber, rawget
local match, gmatch, lower, gsub, strip, find = string.match, string.gmatch, string.lower, string.gsub, string.strip, string.find
local char, byte, sub = string.char, string.byte, string.sub
local abs = math.abs
local bxor, rshift = bit32.bxor, bit32.rshift
local P, S, R, Cmt, C, Ct, Cs, Carg = lpeg.P, lpeg.S, lpeg.R, lpeg.Cmt, lpeg.C, lpeg.Ct, lpeg.Cs, lpeg.Carg
local lpegmatch, patterns = lpeg.match, lpeg.patterns

local trace_features     = false  trackers.register("afm.features",   function(v) trace_features = v end)
local trace_indexing     = false  trackers.register("afm.indexing",   function(v) trace_indexing = v end)
local trace_loading      = false  trackers.register("afm.loading",    function(v) trace_loading  = v end)
local trace_defining     = false  trackers.register("fonts.defining", function(v) trace_defining = v end)

local report_afm         = logs.reporter("fonts","afm loading")

local setmetatableindex  = table.setmetatableindex
local derivetable        = table.derive

local findbinfile        = resolvers.findbinfile

local definers           = fonts.definers
local readers            = fonts.readers
local constructors       = fonts.constructors

local afm                = constructors.newhandler("afm")
local pfb                = constructors.newhandler("pfb")
local otf                = fonts.handlers.otf

local otfreaders         = otf.readers
local otfenhancers       = otf.enhancers

local afmfeatures        = constructors.newfeatures("afm")
local registerafmfeature = afmfeatures.register

afm.version              = 1.507 -- incrementing this number one up will force a re-cache
afm.cache                = containers.define("fonts", "afm", afm.version, true)
afm.autoprefixed         = true -- this will become false some day (catches texnansi-blabla.*)

afm.helpdata             = { }  -- set later on so no local for this
afm.syncspace            = true -- when true, nicer stretch values

local overloads          = fonts.mappings.overloads

local applyruntimefixes  = fonts.treatments and fonts.treatments.applyfixes

--[[ldx--
<p>We start with the basic reader which we give a name similar to the built in <l n='tfm'/>
and <l n='otf'/> reader.</p>
--ldx]]--

-- Comment FONTIDENTIFIER LMMATHSYMBOLS10
-- Comment CODINGSCHEME TEX MATH SYMBOLS
-- Comment DESIGNSIZE 10.0 pt
-- Comment CHECKSUM O 4261307036
-- Comment SPACE 0 plus 0 minus 0
-- Comment QUAD 1000
-- Comment EXTRASPACE 0
-- Comment NUM 676.508 393.732 443.731
-- Comment DENOM 685.951 344.841
-- Comment SUP 412.892 362.892 288.889
-- Comment SUB 150 247.217
-- Comment SUPDROP 386.108
-- Comment SUBDROP 50
-- Comment DELIM 2390 1010
-- Comment AXISHEIGHT 250

--[[ldx--
<p>We now use a new (unfinished) pfb loader but I see no differences between the old
and new vectors (we actually had one bad vector with the old loader).</p>
--ldx]]--

local get_indexes

do

    local n, m

    local progress = function(str,position,name,size)
        local forward = position + tonumber(size) + 3 + 2
        n = n + 1
        if n >= m then
            return #str, name
        elseif forward < #str then
            return forward, name
        else
            return #str, name
        end
    end

    local initialize = function(str,position,size)
        n = 0
        m = tonumber(size)
        return position + 1
    end

    local charstrings = P("/CharStrings")
    local name        = P("/") * C((R("az")+R("AZ")+R("09")+S("-_."))^1)
    local size        = C(R("09")^1)
    local spaces      = P(" ")^1

    local p_filternames = Ct (
        (1-charstrings)^0 * charstrings * spaces * Cmt(size,initialize)
      * (Cmt(name * P(" ")^1 * C(R("09")^1), progress) + P(1))^1
    )

    -- if one of first 4 not 0-9A-F then binary else hex

    local decrypt

    do

        local r, c1, c2, n = 0, 0, 0, 0

        local function step(c)
            local cipher = byte(c)
            local plain  = bxor(cipher,rshift(r,8))
            r = ((cipher + r) * c1 + c2) % 65536
            return char(plain)
        end

        decrypt = function(binary)
            r, c1, c2, n = 55665, 52845, 22719, 4
            binary       = gsub(binary,".",step)
            return sub(binary,n+1)
        end

     -- local pattern = Cs((P(1) / step)^1)
     --
     -- decrypt = function(binary)
     --     r, c1, c2, n = 55665, 52845, 22719, 4
     --     binary = lpegmatch(pattern,binary)
     --     return sub(binary,n+1)
     -- end

    end

    local function loadpfbvector(filename)
        -- for the moment limited to encoding only

        local data = io.loaddata(resolvers.findfile(filename))

        if not find(data,"!PS%-AdobeFont%-") then
            print("no font",filename)
            return
        end

        if not data then
            print("no data",filename)
            return
        end

        local ascii, binary = match(data,"(.*)eexec%s+......(.*)")

        if not binary then
            print("no binary",filename)
            return
        end

        binary = decrypt(binary,4)

        local vector = lpegmatch(p_filternames,binary)

        vector[0] = table.remove(vector,1)

        if not vector then
            print("no vector",filename)
            return
        end

        return vector

    end

    get_indexes = function(data,pfbname)
        local vector = loadpfbvector(pfbname)
        if vector then
            local characters = data.characters
            if trace_loading then
                report_afm("getting index data from %a",pfbname)
            end
            for index=1,#vector do
                local name = vector[index]
                local char = characters[name]
                if char then
                    if trace_indexing then
                        report_afm("glyph %a has index %a",name,index)
                    end
                    char.index = index
                end
            end
        end
    end

end

--[[ldx--
<p>We start with the basic reader which we give a name similar to the built in <l n='tfm'/>
and <l n='otf'/> reader.</p>
--ldx]]--

-- Comment FONTIDENTIFIER LMMATHSYMBOLS10
-- Comment CODINGSCHEME TEX MATH SYMBOLS
-- Comment DESIGNSIZE 10.0 pt
-- Comment CHECKSUM O 4261307036
-- Comment SPACE 0 plus 0 minus 0
-- Comment QUAD 1000
-- Comment EXTRASPACE 0
-- Comment NUM 676.508 393.732 443.731
-- Comment DENOM 685.951 344.841
-- Comment SUP 412.892 362.892 288.889
-- Comment SUB 150 247.217
-- Comment SUPDROP 386.108
-- Comment SUBDROP 50
-- Comment DELIM 2390 1010
-- Comment AXISHEIGHT 250
-- Comment DesignSize 12 (pts)
-- Comment TFM designsize: 12 (in points)

local parser  do -- no need for a further speedup with locals

    local spacing   = patterns.spacer
    local lineend   = patterns.newline
    local number    = spacing * (R("09") + S("."))^1 / tonumber
    local name      = spacing * C((1-spacing)^1)
    local words     = spacing * (1 - lineend)^1 / strip
    local rest      = (1 - lineend)^0
    local fontdata  = Carg(1)
    local semicolon = spacing * P(";")
    local plus      = P("plus") * number
    local minus     = P("minus") * number

    -- kern pairs

    local function addkernpair(data,one,two,value)
        local chr = data.characters[one]
        if chr then
            local kerns = chr.kerns
            if kerns then
                kerns[two] = tonumber(value)
            else
                chr.kerns = { [two] = tonumber(value) }
            end
        end
    end

    local p_kernpair = (fontdata * P("KPX") * name * name * number) / addkernpair

    -- char metrics

    local chr = false
    local ind = 0

    local function start()
        ind = 0
        chr = { }
    end

    local function stop()
        ind = 0
        chr = false
    end

    local function setindex(i)
        if i < 0 then
            ind = ind + 1 -- ?
        else
            ind = i
        end
        chr = {
            index = ind
        }
    end

    local function setwidth(width)
        chr.width = width
    end

    local function setname(data,name)
        data.characters[name] = chr
    end

    local function setboundingbox(boundingbox)
        chr.boundingbox = boundingbox
    end

    local function setligature(plus,becomes)
        local ligatures = chr.ligatures
        if ligatures then
            ligatures[plus] = becomes
        else
            chr.ligatures = { [plus] = becomes }
        end
    end

    local p_charmetric = ( (
        P("C")  * number          / setindex
      + P("WX") * number          / setwidth
      + P("N")  * fontdata * name / setname
      + P("B")  * Ct((number)^4)  / setboundingbox
      + P("L")  * (name)^2        / setligature
      ) * semicolon )^1

    local p_charmetrics = P("StartCharMetrics") * number * (p_charmetric + (1-P("EndCharMetrics")))^0 * P("EndCharMetrics")
    local p_kernpairs   = P("StartKernPairs")   * number * (p_kernpair   + (1-P("EndKernPairs"))  )^0 * P("EndKernPairs")

    local function set_1(data,key,a)     data.metadata[lower(key)] = a           end
    local function set_2(data,key,a,b)   data.metadata[lower(key)] = { a, b }    end
    local function set_3(data,key,a,b,c) data.metadata[lower(key)] = { a, b, c } end

    local p_parameters = P(false)
      + P("FontName") * fontdata * words / function(data,line)
            data.metadata.fontname = line
            data.metadata.fullname = line
        end
      + P("ItalicAngle") * fontdata * number / function(data,angle)
            data.metadata.italicangle = angle
        end
      + P("IsFixedPitch") * fontdata * name  / function(data,pitch)
            data.metadata.monospaced = toboolean(pitch,true)
        end
      + P("CharWidth") * fontdata * number / function(data,width)
            data.metadata.charwidth = width
        end
      + P("XHeight") * fontdata * number / function(data,xheight)
            data.metadata.xheight = xheight
        end
      + P("Descender") * fontdata * number / function(data,descender)
            data.metadata.descender = descender
        end
      + P("Ascender") * fontdata * number / function(data,ascender)
            data.metadata.ascender = ascender
        end
      + P("Comment") * spacing * ( P(false)
          + (fontdata * C("DESIGNSIZE")     * number                   * rest) / set_1 -- 1
          + (fontdata * C("TFM designsize") * number                   * rest) / set_1
          + (fontdata * C("DesignSize")     * number                   * rest) / set_1
          + (fontdata * C("CODINGSCHEME")   * words                    * rest) / set_1 --
          + (fontdata * C("CHECKSUM")       * number * words           * rest) / set_1 -- 2
          + (fontdata * C("SPACE")          * number * plus * minus    * rest) / set_3 -- 3 4 5
          + (fontdata * C("QUAD")           * number                   * rest) / set_1 -- 6
          + (fontdata * C("EXTRASPACE")     * number                   * rest) / set_1 -- 7
          + (fontdata * C("NUM")            * number * number * number * rest) / set_3 -- 8 9 10
          + (fontdata * C("DENOM")          * number * number          * rest) / set_2 -- 11 12
          + (fontdata * C("SUP")            * number * number * number * rest) / set_3 -- 13 14 15
          + (fontdata * C("SUB")            * number * number          * rest) / set_2 -- 16 17
          + (fontdata * C("SUPDROP")        * number                   * rest) / set_1 -- 18
          + (fontdata * C("SUBDROP")        * number                   * rest) / set_1 -- 19
          + (fontdata * C("DELIM")          * number * number          * rest) / set_2 -- 20 21
          + (fontdata * C("AXISHEIGHT")     * number                   * rest) / set_1 -- 22
        )

    parser = (P("StartFontMetrics") / start)
            * (
                p_charmetrics
              + p_kernpairs
              + p_parameters
              + (1-P("EndFontMetrics"))
              )^0
            * (P("EndFontMetrics") / stop)

end


local data = {
    resources = {
        filename = resolvers.unresolve(filename),
--         version  = afm.version,
        creator  = "context mkiv",
    },
    properties = {
        hasitalics = false,
    },
    goodies = {
    },
    metadata   = {
        filename = file.removesuffix(file.basename(filename))
    },
    characters = {
        -- a temporary store
    },
    descriptions = {
        -- the final store
    },
}

local function readafm(filename)
    local ok, afmblob, size = resolvers.loadbinfile(filename) -- has logging
    if ok and afmblob then
        local data = {
            resources = {
                filename = resolvers.unresolve(filename),
                version  = afm.version,
                creator  = "context mkiv",
            },
            properties = {
                hasitalics = false,
            },
            goodies = {
            },
            metadata   = {
                filename = file.removesuffix(file.basename(filename))
            },
            characters = {
                -- a temporary store
            },
            descriptions = {
                -- the final store
            },
        }
        lpegmatch(parser,afmblob,1,data)
        return data
    else
        if trace_loading then
            report_afm("no valid afm file %a",filename)
        end
        return nil
    end
end

--[[ldx--
<p>We cache files. Caching is taken care of in the loader. We cheat a bit by adding
ligatures and kern information to the afm derived data. That way we can set them faster
when defining a font.</p>

<p>We still keep the loading two phased: first we load the data in a traditional
fashion and later we transform it to sequences. Then we apply some methods also
used in opentype fonts (like <t>tlig</t>).</p>
--ldx]]--

local enhancers = {
    -- It's cleaner to implement them after we've seen what we are
    -- dealing with.
}

local steps     = {
    "unify names",
    "add ligatures",
    "add extra kerns",
    "normalize features",
    "fix names",
--  "add tounicode data",
}

local function applyenhancers(data,filename)
    for i=1,#steps do
        local step     = steps[i]
        local enhancer = enhancers[step]
        if enhancer then
            if trace_loading then
                report_afm("applying enhancer %a",step)
            end
            enhancer(data,filename)
        else
            report_afm("invalid enhancer %a",step)
        end
    end
end

function afm.load(filename)
    filename = resolvers.findfile(filename,'afm') or ""
    if filename ~= "" and not fonts.names.ignoredfile(filename) then
        local name = file.removesuffix(file.basename(filename))
        local data = containers.read(afm.cache,name)
        local attr = lfs.attributes(filename)
        local size, time = attr.size or 0, attr.modification or 0
        --
        local pfbfile = file.replacesuffix(name,"pfb")
        local pfbname = resolvers.findfile(pfbfile,"pfb") or ""
        if pfbname == "" then
            pfbname = resolvers.findfile(file.basename(pfbfile),"pfb") or ""
        end
        local pfbsize, pfbtime = 0, 0
        if pfbname ~= "" then
            local attr = lfs.attributes(pfbname)
            pfbsize = attr.size or 0
            pfbtime = attr.modification or 0
        end
        if not data or data.size ~= size or data.time ~= time or data.pfbsize ~= pfbsize or data.pfbtime ~= pfbtime then
            report_afm("reading %a",filename)
            data = readafm(filename)
            if data then
                if pfbname ~= "" then
                    data.resources.filename = resolvers.unresolve(pfbname)
                    get_indexes(data,pfbname)
                elseif trace_loading then
                    report_afm("no pfb file for %a",filename)
                 -- data.resources.filename = "unset" -- better than loading the afm file
                end
                -- we now have all the data loaded
                applyenhancers(data,filename)
             -- otfreaders.addunicodetable(data) -- only when not done yet
                fonts.mappings.addtounicode(data,filename)
             -- otfreaders.extend(data)
                otfreaders.pack(data)
                data.size = size
                data.time = time
                data.pfbsize = pfbsize
                data.pfbtime = pfbtime
                report_afm("saving %a in cache",name)
             -- data.resources.unicodes = nil -- consistent with otf but here we save not much
                data = containers.write(afm.cache, name, data)
                data = containers.read(afm.cache,name)
            end
        end
        if data then
         -- constructors.addcoreunicodes(unicodes)
            otfreaders.unpack(data)
            otfreaders.expand(data) -- inline tables
            otfreaders.addunicodetable(data) -- only when not done yet
            otfenhancers.apply(data,filename,data)
            if applyruntimefixes then
                applyruntimefixes(filename,data)
            end
        end
        return data
    end
end

-- we run a more advanced analyzer later on anyway

local uparser = fonts.mappings.makenameparser() -- each time

enhancers["unify names"] = function(data, filename)
    local unicodevector = fonts.encodings.agl.unicodes -- loaded runtime in context
    local unicodes      = { }
    local names         = { }
    local private       = constructors.privateoffset
    local descriptions  = data.descriptions
    for name, blob in next, data.characters do
        local code = unicodevector[name] -- or characters.name_to_unicode[name]
        if not code then
            code = lpegmatch(uparser,name)
            if type(code) ~= "number" then
                code = private
                private = private + 1
                report_afm("assigning private slot %U for unknown glyph name %a",code,name)
            end
        end
        local index = blob.index
        unicodes[name] = code
        names[name] = index
        blob.name = name
        descriptions[code] = {
            boundingbox = blob.boundingbox,
            width       = blob.width,
            kerns       = blob.kerns,
            index       = index,
            name        = name,
        }
    end
    for unicode, description in next, descriptions do
        local kerns = description.kerns
        if kerns then
            local krn = { }
            for name, kern in next, kerns do
                local unicode = unicodes[name]
                if unicode then
                    krn[unicode] = kern
                else
                 -- print(unicode,name)
                end
            end
            description.kerns = krn
        end
    end
    data.characters = nil
    local resources = data.resources
    local filename = resources.filename or file.removesuffix(file.basename(filename))
    resources.filename = resolvers.unresolve(filename) -- no shortcut
    resources.unicodes = unicodes -- name to unicode
    resources.marks = { } -- todo
 -- resources.names = names -- name to index
    resources.private = private
end

local everywhere = { ["*"] = { ["*"] = true } } -- or: { ["*"] = { "*" } }
local noflags    = { false, false, false, false }

enhancers["normalize features"] = function(data)
    local ligatures  = setmetatableindex("table")
    local kerns      = setmetatableindex("table")
    local extrakerns = setmetatableindex("table")
    for u, c in next, data.descriptions do
        local l = c.ligatures
        local k = c.kerns
        local e = c.extrakerns
        if l then
            ligatures[u] = l
            for u, v in next, l do
                l[u] = { ligature = v }
            end
            c.ligatures = nil
        end
        if k then
            kerns[u] = k
            for u, v in next, k do
                k[u] = v -- { v, 0 }
            end
            c.kerns = nil
        end
        if e then
            extrakerns[u] = e
            for u, v in next, e do
                e[u] = v -- { v, 0 }
            end
            c.extrakerns = nil
        end
    end
    local features = {
        gpos = { },
        gsub = { },
    }
    local sequences = {
        -- only filled ones
    }
    if next(ligatures) then
        features.gsub.liga = everywhere
        data.properties.hasligatures = true
        sequences[#sequences+1] = {
            features = {
                liga = everywhere,
            },
            flags    = noflags,
            name     = "s_s_0",
            nofsteps = 1,
            order    = { "liga" },
            type     = "gsub_ligature",
            steps    = {
                {
                    coverage = ligatures,
                },
            },
        }
    end
    if next(kerns) then
        features.gpos.kern = everywhere
        data.properties.haskerns = true
        sequences[#sequences+1] = {
            features = {
                kern = everywhere,
            },
            flags    = noflags,
            name     = "p_s_0",
            nofsteps = 1,
            order    = { "kern" },
            type     = "gpos_pair",
            steps    = {
                {
                    format   = "kern",
                    coverage = kerns,
                },
            },
        }
    end
    if next(extrakerns) then
        features.gpos.extrakerns = everywhere
        data.properties.haskerns = true
        sequences[#sequences+1] = {
            features = {
                extrakerns = everywhere,
            },
            flags    = noflags,
            name     = "p_s_1",
            nofsteps = 1,
            order    = { "extrakerns" },
            type     = "gpos_pair",
            steps    = {
                {
                    format   = "kern",
                    coverage = extrakerns,
                },
            },
        }
    end
    -- todo: compress kerns
    data.resources.features  = features
    data.resources.sequences = sequences
end

enhancers["fix names"] = function(data)
    for k, v in next, data.descriptions do
        local n = v.name
        local r = overloads[n]
        if r then
            local name = r.name
            if trace_indexing then
                report_afm("renaming characters %a to %a",n,name)
            end
            v.name    = name
            v.unicode = r.unicode
        end
    end
end

--[[ldx--
<p>These helpers extend the basic table with extra ligatures, texligatures
and extra kerns. This saves quite some lookups later.</p>
--ldx]]--

local addthem = function(rawdata,ligatures)
    if ligatures then
        local descriptions = rawdata.descriptions
        local resources    = rawdata.resources
        local unicodes     = resources.unicodes
     -- local names        = resources.names
        for ligname, ligdata in next, ligatures do
            local one = descriptions[unicodes[ligname]]
            if one then
                for _, pair in next, ligdata do
                    local two, three = unicodes[pair[1]], unicodes[pair[2]]
                    if two and three then
                        local ol = one.ligatures
                        if ol then
                            if not ol[two] then
                                ol[two] = three
                            end
                        else
                            one.ligatures = { [two] = three }
                        end
                    end
                end
            end
        end
    end
end

enhancers["add ligatures"] = function(rawdata)
    addthem(rawdata,afm.helpdata.ligatures)
end

-- enhancers["add tex ligatures"] = function(rawdata)
--     addthem(rawdata,afm.helpdata.texligatures)
-- end

--[[ldx--
<p>We keep the extra kerns in separate kerning tables so that we can use
them selectively.</p>
--ldx]]--

-- This is rather old code (from the beginning when we had only tfm). If
-- we unify the afm data (now we have names all over the place) then
-- we can use shcodes but there will be many more looping then. But we
-- could get rid of the tables in char-cmp then. Als, in the generic version
-- we don't use the character database. (Ok, we can have a context specific
-- variant).

enhancers["add extra kerns"] = function(rawdata) -- using shcodes is not robust here
    local descriptions = rawdata.descriptions
    local resources    = rawdata.resources
    local unicodes     = resources.unicodes
    local function do_it_left(what)
        if what then
            for unicode, description in next, descriptions do
                local kerns = description.kerns
                if kerns then
                    local extrakerns
                    for complex, simple in next, what do
                        complex = unicodes[complex]
                        simple = unicodes[simple]
                        if complex and simple then
                            local ks = kerns[simple]
                            if ks and not kerns[complex] then
                                if extrakerns then
                                    extrakerns[complex] = ks
                                else
                                    extrakerns = { [complex] = ks }
                                end
                            end
                        end
                    end
                    if extrakerns then
                        description.extrakerns = extrakerns
                    end
                end
            end
        end
    end
    local function do_it_copy(what)
        if what then
            for complex, simple in next, what do
                complex = unicodes[complex]
                simple = unicodes[simple]
                if complex and simple then
                    local complexdescription = descriptions[complex]
                    if complexdescription then -- optional
                        local simpledescription = descriptions[complex]
                        if simpledescription then
                            local extrakerns
                            local kerns = simpledescription.kerns
                            if kerns then
                                for unicode, kern in next, kerns do
                                    if extrakerns then
                                        extrakerns[unicode] = kern
                                    else
                                        extrakerns = { [unicode] = kern }
                                    end
                                end
                            end
                            local extrakerns = simpledescription.extrakerns
                            if extrakerns then
                                for unicode, kern in next, extrakerns do
                                    if extrakerns then
                                        extrakerns[unicode] = kern
                                    else
                                        extrakerns = { [unicode] = kern }
                                    end
                                end
                            end
                            if extrakerns then
                                complexdescription.extrakerns = extrakerns
                            end
                        end
                    end
                end
            end
        end
    end
    -- add complex with values of simplified when present
    do_it_left(afm.helpdata.leftkerned)
    do_it_left(afm.helpdata.bothkerned)
    -- copy kerns from simple char to complex char unless set
    do_it_copy(afm.helpdata.bothkerned)
    do_it_copy(afm.helpdata.rightkerned)
end

--[[ldx--
<p>The copying routine looks messy (and is indeed a bit messy).</p>
--ldx]]--

local function adddimensions(data) -- we need to normalize afm to otf i.e. indexed table instead of name
    if data then
        for unicode, description in next, data.descriptions do
            local bb = description.boundingbox
            if bb then
                local ht, dp = bb[4], -bb[2]
                if ht == 0 or ht < 0 then
                    -- no need to set it and no negative heights, nil == 0
                else
                    description.height = ht
                end
                if dp == 0 or dp < 0 then
                    -- no negative depths and no negative depths, nil == 0
                else
                    description.depth  = dp
                end
            end
        end
    end
end

local function copytotfm(data)
    if data and data.descriptions then
        local metadata     = data.metadata
        local resources    = data.resources
        local properties   = derivetable(data.properties)
        local descriptions = derivetable(data.descriptions)
        local goodies      = derivetable(data.goodies)
        local characters   = { }
        local parameters   = { }
        local unicodes     = resources.unicodes
        --
        for unicode, description in next, data.descriptions do -- use parent table
            characters[unicode] = { }
        end
        --
        local filename   = constructors.checkedfilename(resources)
        local fontname   = metadata.fontname or metadata.fullname
        local fullname   = metadata.fullname or metadata.fontname
        local endash     = 0x0020 -- space
        local emdash     = 0x2014
        local spacer     = "space"
        local spaceunits = 500
        --
        local monospaced  = metadata.monospaced
        local charwidth   = metadata.charwidth
        local italicangle = metadata.italicangle
        local charxheight = metadata.xheight and metadata.xheight > 0 and metadata.xheight
        properties.monospaced  = monospaced
        parameters.italicangle = italicangle
        parameters.charwidth   = charwidth
        parameters.charxheight = charxheight
        -- same as otf
        if properties.monospaced then
            if descriptions[endash] then
                spaceunits, spacer = descriptions[endash].width, "space"
            end
            if not spaceunits and descriptions[emdash] then
                spaceunits, spacer = descriptions[emdash].width, "emdash"
            end
            if not spaceunits and charwidth then
                spaceunits, spacer = charwidth, "charwidth"
            end
        else
            if descriptions[endash] then
                spaceunits, spacer = descriptions[endash].width, "space"
            end
            if not spaceunits and charwidth then
                spaceunits, spacer = charwidth, "charwidth"
            end
        end
        spaceunits = tonumber(spaceunits)
        if spaceunits < 200 then
            -- todo: warning
        end
        --
        parameters.slant         = 0
        parameters.space         = spaceunits
        parameters.space_stretch = 500
        parameters.space_shrink  = 333
        parameters.x_height      = 400
        parameters.quad          = 1000
        --
        if italicangle and italicangle ~= 0 then
            parameters.italicangle  = italicangle
            parameters.italicfactor = math.cos(math.rad(90+italicangle))
            parameters.slant        = - math.tan(italicangle*math.pi/180)
        end
        if monospaced then
            parameters.space_stretch = 0
            parameters.space_shrink  = 0
        elseif afm.syncspace then
            parameters.space_stretch = spaceunits/2
            parameters.space_shrink  = spaceunits/3
        end
        parameters.extra_space = parameters.space_shrink
        if charxheight then
            parameters.x_height = charxheight
        else
            -- same as otf
            local x = 0x0078 -- x
            if x then
                local x = descriptions[x]
                if x then
                    parameters.x_height = x.height
                end
            end
            --
        end
        --
        if metadata.sup then
            local dummy    = { 0, 0, 0}
            parameters[ 1] = metadata.designsize or 0
            parameters[ 2] = metadata.checksum or 0
            parameters[ 3],
            parameters[ 4],
            parameters[ 5] = unpack(metadata.space or dummy)
            parameters[ 6] = metadata.quad or 0
            parameters[ 7] = metadata.extraspace or 0
            parameters[ 8],
            parameters[ 9],
            parameters[10] = unpack(metadata.num or dummy)
            parameters[11],
            parameters[12] = unpack(metadata.denom or dummy)
            parameters[13],
            parameters[14],
            parameters[15] = unpack(metadata.sup or dummy)
            parameters[16],
            parameters[17] = unpack(metadata.sub or dummy)
            parameters[18] = metadata.supdrop or 0
            parameters[19] = metadata.subdrop or 0
            parameters[20],
            parameters[21] = unpack(metadata.delim or dummy)
            parameters[22] = metadata.axisheight
        end
        --
        parameters.designsize = (metadata.designsize or 10)*65536
        parameters.ascender   = abs(metadata.ascender  or 0)
        parameters.descender  = abs(metadata.descender or 0)
        parameters.units      = 1000
        --
        properties.spacer        = spacer
        properties.encodingbytes = 2
        properties.format        = fonts.formats[filename] or "type1"
        properties.filename      = filename
        properties.fontname      = fontname
        properties.fullname      = fullname
        properties.psname        = fullname
        properties.name          = filename or fullname or fontname
        --
        if next(characters) then
            return {
                characters   = characters,
                descriptions = descriptions,
                parameters   = parameters,
                resources    = resources,
                properties   = properties,
                goodies      = goodies,
            }
        end
    end
    return nil
end

--[[ldx--
<p>Originally we had features kind of hard coded for <l n='afm'/> files but since I
expect to support more font formats, I decided to treat this fontformat like any
other and handle features in a more configurable way.</p>
--ldx]]--

function afm.setfeatures(tfmdata,features)
    local okay = constructors.initializefeatures("afm",tfmdata,features,trace_features,report_afm)
    if okay then
        return constructors.collectprocessors("afm",tfmdata,features,trace_features,report_afm)
    else
        return { } -- will become false
    end
end

local function addtables(data)
    local resources  = data.resources
    local lookuptags = resources.lookuptags
    local unicodes   = resources.unicodes
    if not lookuptags then
        lookuptags = { }
        resources.lookuptags = lookuptags
    end
    setmetatableindex(lookuptags,function(t,k)
        local v = type(k) == "number" and ("lookup " .. k) or k
        t[k] = v
        return v
    end)
    if not unicodes then
        unicodes = { }
        resources.unicodes = unicodes
        setmetatableindex(unicodes,function(t,k)
            setmetatableindex(unicodes,nil)
            for u, d in next, data.descriptions do
                local n = d.name
                if n then
                    t[n] = u
                end
            end
            return rawget(t,k)
        end)
    end
    constructors.addcoreunicodes(unicodes) -- do we really need this?
end

local function afmtotfm(specification)
    local afmname = specification.filename or specification.name
    if specification.forced == "afm" or specification.format == "afm" then -- move this one up
        if trace_loading then
            report_afm("forcing afm format for %a",afmname)
        end
    else
        local tfmname = findbinfile(afmname,"ofm") or ""
        if tfmname ~= "" then
            if trace_loading then
                report_afm("fallback from afm to tfm for %a",afmname)
            end
            return -- just that
        end
    end
    if afmname ~= "" then
        -- weird, isn't this already done then?
        local features = constructors.checkedfeatures("afm",specification.features.normal)
        specification.features.normal = features
        constructors.hashinstance(specification,true) -- also weird here
        --
        specification = definers.resolve(specification) -- new, was forgotten
        local cache_id = specification.hash
        local tfmdata  = containers.read(constructors.cache, cache_id) -- cache with features applied
        if not tfmdata then
            local rawdata = afm.load(afmname)
            if rawdata and next(rawdata) then
                addtables(rawdata)
                adddimensions(rawdata)
                tfmdata = copytotfm(rawdata)
                if tfmdata and next(tfmdata) then
                    local shared = tfmdata.shared
                    if not shared then
                        shared         = { }
                        tfmdata.shared = shared
                    end
                    shared.rawdata   = rawdata
                    shared.dynamics  = { }
                    tfmdata.changed  = { }
                    shared.features  = features
                    shared.processes = afm.setfeatures(tfmdata,features)
                end
            elseif trace_loading then
                report_afm("no (valid) afm file found with name %a",afmname)
            end
            tfmdata = containers.write(constructors.cache,cache_id,tfmdata)
        end
        return tfmdata
    end
end

--[[ldx--
<p>As soon as we could intercept the <l n='tfm'/> reader, I implemented an
<l n='afm'/> reader. Since traditional <l n='pdftex'/> could use <l n='opentype'/>
fonts with <l n='afm'/> companions, the following method also could handle
those cases, but now that we can handle <l n='opentype'/> directly we no longer
need this features.</p>
--ldx]]--

local function read_from_afm(specification)
    local tfmdata = afmtotfm(specification)
    if tfmdata then
        tfmdata.properties.name = specification.name
        tfmdata = constructors.scale(tfmdata, specification)
        local allfeatures = tfmdata.shared.features or specification.features.normal
        constructors.applymanipulators("afm",tfmdata,allfeatures,trace_features,report_afm)
        fonts.loggers.register(tfmdata,'afm',specification)
    end
    return tfmdata
end

--[[ldx--
<p>We have the usual two modes and related features initializers and processors.</p>
--ldx]]--

local function setmode(tfmdata,value)
    if value then
        tfmdata.properties.mode = lower(value)
    end
end

registerafmfeature {
    name         = "mode",
    description  = "mode",
    initializers = {
        base = setmode,
        node = setmode,
    }
}

registerafmfeature {
    name         = "features",
    description  = "features",
    default      = true,
    initializers = {
        node     = otf.nodemodeinitializer,
        base     = otf.basemodeinitializer,
    },
    processors   = {
        node     = otf.featuresprocessor,
    }
}

-- readers

local check_tfm   = readers.check_tfm

fonts.formats.afm = "type1"
fonts.formats.pfb = "type1"

local function check_afm(specification,fullname)
    local foundname = findbinfile(fullname, 'afm') or "" -- just to be sure
    if foundname == "" then
        foundname = fonts.names.getfilename(fullname,"afm") or ""
    end
    if foundname == "" and afm.autoprefixed then
        local encoding, shortname = match(fullname,"^(.-)%-(.*)$") -- context: encoding-name.*
        if encoding and shortname and fonts.encodings.known[encoding] then
            shortname = findbinfile(shortname,'afm') or "" -- just to be sure
            if shortname ~= "" then
                foundname = shortname
                if trace_defining then
                    report_afm("stripping encoding prefix from filename %a",afmname)
                end
            end
        end
    end
    if foundname ~= "" then
        specification.filename = foundname
        specification.format   = "afm"
        return read_from_afm(specification)
    end
end

function readers.afm(specification,method)
    local fullname, tfmdata = specification.filename or "", nil
    if fullname == "" then
        local forced = specification.forced or ""
        if forced ~= "" then
            tfmdata = check_afm(specification,specification.name .. "." .. forced)
        end
        if not tfmdata then
            method = method or definers.method or "afm or tfm"
            if method == "tfm" then
                tfmdata = check_tfm(specification,specification.name)
            elseif method == "afm" then
                tfmdata = check_afm(specification,specification.name)
            elseif method == "tfm or afm" then
                tfmdata = check_tfm(specification,specification.name) or check_afm(specification,specification.name)
            else -- method == "afm or tfm" or method == "" then
                tfmdata = check_afm(specification,specification.name) or check_tfm(specification,specification.name)
            end
        end
    else
        tfmdata = check_afm(specification,fullname)
    end
    return tfmdata
end

function readers.pfb(specification,method) -- only called when forced
    local original = specification.specification
    if trace_defining then
        report_afm("using afm reader for %a",original)
    end
    specification.specification = file.replacesuffix(original,"afm")
    specification.forced = "afm"
    return readers.afm(specification,method)
end