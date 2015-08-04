#!/usr/bin/env luajit
do local sources = {};sources["hate.graphics"]=([[-- <pack hate.graphics> --
local current_folder = (...):gsub('%.\[^%.\]+$', '') .. "."
local sdl = require(current_folder .. "sdl2")
local ffi = require "ffi"
local cpml = require(current_folder .. "cpml")

local graphics = {}

local function load_shader(src, type)
	local function validate(shader)
		local int = ffi.new("GLint\[1\]")
		gl.GetShaderiv(shader, GL.INFO_LOG_LENGTH, int)
		local length = int\[0\]
		if length <= 0 then
			return
		end
		gl.GetShaderiv(shader, GL.COMPILE_STATUS, int)
		local success = int\[0\]
		if success == GL.TRUE then
			return
		end
		local buffer = ffi.new("char\[?\]", length)
		gl.GetShaderInfoLog(shader, length, int, buffer)
		error(ffi.string(buffer))
	end
	local shader = gl.CreateShader(type)
	if shader == 0 then
		error("glGetError: " .. tonumber(gl.GetError()))
	end
	local src = ffi.new("char\[?\]", #src, src)
	local srcs = ffi.new("const char*\[1\]", src)
	gl.ShaderSource(shader, 1, srcs, nil)
	gl.CompileShader(shader)
	validate(shader)
	return {
		handle = shader,
		type = type
	}
end

local function assemble_program(...)
	local shaders = {...}

	local prog = gl.CreateProgram()
	for _, shader in ipairs(shaders) do
		gl.AttachShader(prog, shader.handle)
	end
	gl.LinkProgram(prog)
	gl.UseProgram(prog)

	return {
		handle = prog
	}
end

function graphics.clear(color, depth)
	local w, h = graphics.getDimensions()
	gl.Viewport(0, 0, w, h)

	local mask = 0
	if color == nil or color then
		mask = bit.bor(mask, tonumber(GL.COLOR_BUFFER_BIT))
	end
	if depth then
		mask = bit.bor(mask, tonumber(GL.DEPTH_BUFFER_BIT))
	end
	gl.Clear(mask)
end

function graphics.getBackgroundColor()
	return graphics._background_color or { 0, 0, 0, 0 }
end

function graphics.setBackgroundColor(r, g, b, a)
	if type(r) == "table" then
		r, g, b, a = r\[1\], r\[2\], r\[3\], r\[4\] or 255
	end
	graphics._background_color = { r, g, b, a }
	gl.ClearColor(r / 255, g / 255, b / 255, a / 255)
end

function graphics.getColor()
	return graphics._color or { 0, 0, 0, 0 }
end

function graphics.setColor(r, g, b, a)
	if type(r) == "table" then
		r, g, b, a = r\[1\], r\[2\], r\[3\], r\[4\] or 255
	end
	graphics._color = { r, g, b, a }

	-- this should update the default shader with _color
end

function graphics.getDimensions()
	local w, h = ffi.new("int\[1\]"), ffi.new("int\[1\]")
	sdl.GL_GetDrawableSize(graphics._state.window, w, h)

	return tonumber(w\[0\]), tonumber(h\[0\])
end

function graphics.getWidth()
	return select(1, graphics.getDimensions())
end

function graphics.getHeight()
	return select(2, graphics.getDimensions())
end

function graphics.isWireframe()
	return graphics._wireframe.enable and true or false
end

function graphics.setWireframe(enable)
	graphics._wireframe.enable = enable and true or false
	gl.PolygonMode(GL.FRONT_AND_BACK, enable and GL.LINE or GL.FILL)
end

function graphics.setStencil(stencilfn)
	if stencilfn then
		-- gl.Enable(GL.STENCIL_TEST)
		-- write to stencil buffer using stencilfn
		-- etc
	else
		-- gl.Disable(GL.STENCIL_TEST)
	end
end

-- should do the same thing as setStencil, but, well, inverted.
function graphics.setInvertedStencil(stencilfn)

end

local function elements_for_mode(buffer_type)
	local t = {
		\[GL.TRIANGLES\] = 3,
		\[GL.TRIANGLE_STRIP\] = 1,
		\[GL.LINES\] = 2,
		\[GL.POINTS\] = 1
	}
	assert(t\[buffer_type\])
	return t\[buffer_type\]
end

local function submit_buffer(buffer_type, mode, data, count)
	local handle = ffi.new("GLuint\[1\]")
	gl.GenBuffers(1, handle)
	ffi.gc(handle, function(h) gl.DeleteBuffers(1, h) end)
	gl.BindBuffer(buffer_type, handle\[0\])
	gl.BufferData(buffer_type, ffi.sizeof(data), data, GL.STATIC_DRAW)
	return {
		buffer_type = buffer_type,
		count  = count,
		mode   = mode,
		handle = handle
	}
end

local function send_uniform(shader, name, data, is_int)
	-- just a number, ez
	-- this should probably just use the *v stuff, so it doesn't need its own codepath.
	if type(data) == "number" then
		local loc = gl.GetUniformLocation(shader, name)
		local send = is_int and gl.Uniform1f or gl.Uniform1i
		send(loc, data)
	end
	-- it's either a vector or matrix type
	-- TODO: Uniform arrays
	if type(data) == "table" then
		if type(data\[1\]) == "table" then
			-- matrix
			-- we support any matrix between 2x2 and 4x4 as long as it makes sense.
			assert(#data >= 2 and #data <= 4, "Unsupported column size for matrix: " .. #data .. ", must be between 2 and 4.")
			assert(#data\[1\] == #data\[2\] == #data\[3\] == #data\[4\], "All rows in a matrix must be the same size.")
			assert(#data\[1\] >= 2 and #data\[1\] <= 4, "Unsupported row size for matrix: " .. #data\[1\] .. ", must be between 2 and 4.")
			local mtype = #data == #data\[1\] and tostring(#data) or tostring(#data) .. "x" .. tostring(#data\[1\])
			local fn = "UniformMatrix" .. mtype .. "fv"
			gl\[fn\](loc, count, GL.FALSE, data)
		else
			-- vector
			assert(#data >= 2 and #data <= 4, "Unsupported size for vector type: " .. #data .. ", must be between 2 and 4.")
			local fn = "Uniform" .. tostring(#data) .. "fv"
			gl\[fn\](loc, count, data)
		end
	end
end

function graphics.push(which)
	local stack = graphics._state.stack
	assert(#stack < 64, "Stack overflow - your stack is too deep, did you forget to pop?")
	if #stack == 0 then
		table.insert(stack, {
			matrix = cpml.mat4(),
			color = { 255, 255, 255, 255 },
			active_shader = graphics._active_shader,
			wireframe = graphics._wireframe
		})
	else
		local top = stack\[#stack\]
		local new = {
			matrix = top.matrix:clone(),
			color  = top.color,
			active_shader = top.active_shader,
			wireframe = top.wireframe
		}
		if which == "all" then
			new.color = { top.color\[1\], top.color\[2\], top.color\[3\], top.color\[4\] }
			new.active_shader = { handle = top.active_shader.handle }
			new.wireframe = { enable = top.wireframe.enable }
		end
		table.insert(stack, new)
	end
	graphics._state.stack_top = stack\[#stack\]
end

function graphics.pop()
	local stack = graphics._state.stack
	assert(#stack > 1, "Stack underflow - you've popped more than you pushed!")
	table.remove(stack)

	local top = stack\[#stack\]
	graphics._state.stack_top = top
	graphics.setShader(top.active_shader)
	graphics.setColor(top.color)
	graphics.setWireframe(top.wireframe.enable)
end

function graphics.translate(x, y)
	local top = graphics._state.stack_top
	top.matrix = top.matrix:translate(cpml.vec3(x, y, 0))
end

function graphics.rotate(r)
	assert(type(r) == "number")
	local top = graphics._state.stack_top
	top.matrix = top.matrix:rotate(r, { 0, 0, 1 })
end

function graphics.scale(x, y)
	local top = graphics._state.stack_top
	top.matrix = top.matrix:scale(cpml.vec3(x, y, 1))
end

function graphics.origin()
	local top = graphics._state.stack_top
	top.matrix = top.matrix:identity()
end

function graphics.circle(mode, x, y, radius, segments)
	segments = segments or 32
	local vertices = {}
	local count = (segments+2) * 2
	local data = ffi.new("float\[?\]", count)

	-- center of fan
	data\[0\] = x
	data\[1\] = y

	for i=0, segments do
		local angle = (i / segments) * math.pi * 2
		data\[(i*2)+2\] = x + math.cos(angle) * radius
		data\[(i*2)+3\] = y + math.sin(angle) * radius
	end

	-- gl.PolygonMode(GL.FRONT_AND_BACK, GL.LINE)

	local buf = submit_buffer(GL.ARRAY_BUFFER, GL.TRIANGLE_FAN, data, count)
	local vao = ffi.new("GLuint\[1\]")
	assert(gl.GetError() == GL.NO_ERROR)
	local shader = graphics._active_shader.handle
	local modelview = graphics._state.stack_top.matrix
	local w, h = graphics.getDimensions()
	local projection = cpml.mat4():ortho(0, w, 0, h, -100, 100)
	local mvp = modelview * projection
	local mat_f  = ffi.new("float\[?\]", 16)
	for i = 1, 16 do
		mat_f\[i-1\] = modelview\[i\]
	end
	gl.UniformMatrix4fv(gl.GetUniformLocation(shader, "HATE_ModelViewMatrix"), 1, false, mat_f)
	for i = 1, 16 do
		mat_f\[i-1\] = projection\[i\]
	end
	gl.UniformMatrix4fv(gl.GetUniformLocation(shader, "HATE_ProjectionMatrix"), 1, false, mat_f)
	for i = 1, 16 do
		mat_f\[i-1\] = mvp\[i\]
	end
	gl.UniformMatrix4fv(gl.GetUniformLocation(shader, "HATE_ModelViewProjectionMatrix"), 1, false, mat_f)
	gl.BindBuffer(buf.buffer_type, buf.handle\[0\])
	gl.EnableVertexAttribArray(0)
	gl.VertexAttribPointer(0, 2, GL.FLOAT, GL.FALSE, 0, ffi.cast("void*", 0))
	gl.DrawArrays(buf.mode, 0, buf.count / 2)
end

function graphics.present()
	sdl.GL_SwapWindow(graphics._state.window)
end

function graphics.origin()
	-- TODO
end

function graphics.reset()
	gl.ClearColor(0, 0, 0, 255)
end

-- todo: different depth functions, range, clear depth
function graphics.setDepthTest(enable)
	if enable ~= nil and graphics._state.depth_test ~= enable then
		if enable then
			gl.Enable(GL.DEPTH_TEST)
		else
			gl.Disable(GL.DEPTH_TEST)
		end
	end
end

	local GLSL_VERSION = "#version 120"

	local GLSL_SYNTAX = \[\[
#define lowp
#define mediump
#define highp
#define number float
#define Image sampler2D
#define extern uniform
#define Texel texture2D
#pragma optionNV(strict on)\]\]

	local GLSL_UNIFORMS = \[\[
#define TransformMatrix HATE_ModelViewMatrix
#define ProjectionMatrix HATE_ProjectionMatrix
#define TransformProjectionMatrix HATE_ModelViewProjectionMatrix

#define NormalMatrix gl_NormalMatrix

uniform mat4 HATE_ModelViewMatrix;
uniform mat4 HATE_ProjectionMatrix;
uniform mat4 HATE_ModelViewProjectionMatrix;

//uniform sampler2D _tex0_;
//uniform vec4 love_ScreenSize;\]\]

	local GLSL_VERTEX = {
		HEADER = \[\[
#define VERTEX

#define VertexPosition gl_Vertex
#define VertexTexCoord gl_MultiTexCoord0
#define VertexColor gl_Color

#define VaryingTexCoord gl_TexCoord\[0\]
#define VaryingColor gl_FrontColor

// #if defined(GL_ARB_draw_instanced)
//	#extension GL_ARB_draw_instanced : enable
//	#define love_InstanceID gl_InstanceIDARB
// #else
//	attribute float love_PseudoInstanceID;
//	int love_InstanceID = int(love_PseudoInstanceID);
// #endif
\]\],

		FOOTER = \[\[
void main() {
	VaryingTexCoord = VertexTexCoord;
	VaryingColor = VertexColor;
	gl_Position = position(TransformProjectionMatrix, VertexPosition);
}\]\],
	}

	local GLSL_PIXEL = {
		HEADER = \[\[
#define PIXEL

#define VaryingTexCoord gl_TexCoord\[0\]
#define VaryingColor gl_Color

#define love_Canvases gl_FragData\]\],

		FOOTER = \[\[
void main() {
	// fix crashing issue in OSX when _tex0_ is unused within effect()
	//float dummy = Texel(_tex0_, vec2(.5)).r;

	// See Shader::checkSetScreenParams in Shader.cpp.
	// exists to fix x/y when using canvases
	//vec2 pixelcoord = vec2(gl_FragCoord.x, (gl_FragCoord.y * love_ScreenSize.z) + love_ScreenSize.w);

	gl_FragColor = vec4(1.0, 1.0, 1.0, 1.0);
	//gl_FragColor = effect(VaryingColor, _tex0_, VaryingTexCoord.st, pixelcoord);
}\]\],

		FOOTER_MULTI_CANVAS = \[\[
void main() {
	// fix crashing issue in OSX when _tex0_ is unused within effect()
	float dummy = Texel(_tex0_, vec2(.5)).r;

	// See Shader::checkSetScreenParams in Shader.cpp.
	vec2 pixelcoord = vec2(gl_FragCoord.x, (gl_FragCoord.y * love_ScreenSize.z) + love_ScreenSize.w);

	effects(VaryingColor, _tex0_, VaryingTexCoord.st, pixelcoord);
}\]\],
	}

local table_concat = table.concat
local function createVertexCode(vertexcode)
	local vertexcodes = {
		GLSL_VERSION,
		GLSL_SYNTAX, GLSL_VERTEX.HEADER, GLSL_UNIFORMS,
		"#line 0",
		vertexcode,
		GLSL_VERTEX.FOOTER,
	}
	return table_concat(vertexcodes, "\n")
end

local function createPixelCode(pixelcode, is_multicanvas)
	local pixelcodes = {
		GLSL_VERSION,
		GLSL_SYNTAX, GLSL_PIXEL.HEADER, GLSL_UNIFORMS,
		"#line 0",
		pixelcode,
		is_multicanvas and GLSL_PIXEL.FOOTER_MULTI_CANVAS or GLSL_PIXEL.FOOTER,
	}
	return table_concat(pixelcodes, "\n")
end

local function isVertexCode(code)
	return code:match("vec4%s+position%s*%(") ~= nil
end

local function isPixelCode(code)
	if code:match("vec4%s+effect%s*%(") then
		return true
	elseif code:match("void%s+effects%s*%(") then
		-- function for rendering to multiple canvases simultaneously
		return true, true
	else
		return false
	end
end

function graphics.newShader(pixelcode, vertexcode)
	local vs
	local fs = load_shader(createPixelCode(pixelcode, false), GL.FRAGMENT_SHADER)
	if vertexcode then
		vs = load_shader(createVertexCode(vertexcode), GL.VERTEX_SHADER)
	end
	if not vertexcode and isVertexCode(pixelcode) then
		vs = load_shader(createVertexCode(pixelcode), GL.VERTEX_SHADER)
	end
	return assemble_program(vs, fs)
end

function graphics.setShader(shader)
	if shader == nil then
		shader = graphics._internal_shader
	end
	if shader ~= graphics._active_shader then
		graphics._active_shader = shader
		gl.UseProgram(shader._program)
	end
end

local default =
\[===\[
#ifdef VERTEX
vec4 position(mat4 transform_proj, vec4 vertpos) {
	return transform_proj * vertpos;
}
#endif

#ifdef PIXEL
vec4 effect(lowp vec4 vcolor, Image tex, vec2 texcoord, vec2 pixcoord) {
	return Texel(tex, texcoord) * vcolor;
}
#endif
\]===\]

function graphics.init()
	if graphics._state.config.window.srgb then
		gl.Enable(GL.FRAMEBUFFER_SRGB)
	end
	graphics._state.stack = {}
	graphics._internal_shader = graphics.newShader(default)
	graphics._active_shader = graphics._internal_shader
	graphics._wireframe = {}
	graphics.setWireframe(false)
	graphics.push("all")
end

return graphics
]]):gsub('\\([%]%[])','%1')
sources["hate.opengl"]=([[-- <pack hate.opengl> --
local ffi = require("ffi")

-- glcorearb.h
local glheader = \[\[
/*
** Copyright (c) 2013-2014 The Khronos Group Inc.
**
** Permission is hereby granted, free of charge, to any person obtaining a
** copy of this software and/or associated documentation files (the
** "Materials"), to deal in the Materials without restriction, including
** without limitation the rights to use, copy, modify, merge, publish,
** distribute, sublicense, and/or sell copies of the Materials, and to
** permit persons to whom the Materials are furnished to do so, subject to
** the following conditions:
**
** The above copyright notice and this permission notice shall be included
** in all copies or substantial portions of the Materials.
**
** THE MATERIALS ARE PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
** EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
** MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.
** IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY
** CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT,
** TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE
** MATERIALS OR THE USE OR OTHER DEALINGS IN THE MATERIALS.
*/
/*
** This header is generated from the Khronos OpenGL / OpenGL ES XML
** API Registry. The current version of the Registry, generator scripts
** used to make the header, and the header can be found at
**   http://www.opengl.org/registry/
**
** Khronos $Revision: 26007 $ on $Date: 2014-03-19 01:28:09 -0700 (Wed, 19 Mar 2014) $
*/

/* glcorearb.h is for use with OpenGL core profile implementations.
** It should should be placed in the same directory as gl.h and
** included as <GL/glcorearb.h>.
**
** glcorearb.h includes only APIs in the latest OpenGL core profile
** implementation together with APIs in newer ARB extensions which 
** can be supported by the core profile. It does not, and never will
** include functionality removed from the core profile, such as
** fixed-function vertex and fragment processing.
**
** Do not #include both <GL/glcorearb.h> and either of <GL/gl.h> or
** <GL/glext.h> in the same source file.
*/

/* Generated C header for:
 * API: gl
 * Profile: core
 * Versions considered: .*
 * Versions emitted: .*
 * Default extensions included: glcore
 * Additional extensions included: _nomatch_^
 * Extensions removed: _nomatch_^
 */

typedef void GLvoid;
typedef unsigned int GLenum;
typedef float GLfloat;
typedef int GLint;
typedef int GLsizei;
typedef unsigned int GLbitfield;
typedef double GLdouble;
typedef unsigned int GLuint;
typedef unsigned char GLboolean;
typedef unsigned char GLubyte;
typedef void (APIENTRYP PFNGLCULLFACEPROC) (GLenum mode);
typedef void (APIENTRYP PFNGLFRONTFACEPROC) (GLenum mode);
typedef void (APIENTRYP PFNGLHINTPROC) (GLenum target, GLenum mode);
typedef void (APIENTRYP PFNGLLINEWIDTHPROC) (GLfloat width);
typedef void (APIENTRYP PFNGLPOINTSIZEPROC) (GLfloat size);
typedef void (APIENTRYP PFNGLPOLYGONMODEPROC) (GLenum face, GLenum mode);
typedef void (APIENTRYP PFNGLSCISSORPROC) (GLint x, GLint y, GLsizei width, GLsizei height);
typedef void (APIENTRYP PFNGLTEXPARAMETERFPROC) (GLenum target, GLenum pname, GLfloat param);
typedef void (APIENTRYP PFNGLTEXPARAMETERFVPROC) (GLenum target, GLenum pname, const GLfloat *params);
typedef void (APIENTRYP PFNGLTEXPARAMETERIPROC) (GLenum target, GLenum pname, GLint param);
typedef void (APIENTRYP PFNGLTEXPARAMETERIVPROC) (GLenum target, GLenum pname, const GLint *params);
typedef void (APIENTRYP PFNGLTEXIMAGE1DPROC) (GLenum target, GLint level, GLint internalformat, GLsizei width, GLint border, GLenum format, GLenum type, const void *pixels);
typedef void (APIENTRYP PFNGLTEXIMAGE2DPROC) (GLenum target, GLint level, GLint internalformat, GLsizei width, GLsizei height, GLint border, GLenum format, GLenum type, const void *pixels);
typedef void (APIENTRYP PFNGLDRAWBUFFERPROC) (GLenum mode);
typedef void (APIENTRYP PFNGLCLEARPROC) (GLbitfield mask);
typedef void (APIENTRYP PFNGLCLEARCOLORPROC) (GLfloat red, GLfloat green, GLfloat blue, GLfloat alpha);
typedef void (APIENTRYP PFNGLCLEARSTENCILPROC) (GLint s);
typedef void (APIENTRYP PFNGLCLEARDEPTHPROC) (GLdouble depth);
typedef void (APIENTRYP PFNGLSTENCILMASKPROC) (GLuint mask);
typedef void (APIENTRYP PFNGLCOLORMASKPROC) (GLboolean red, GLboolean green, GLboolean blue, GLboolean alpha);
typedef void (APIENTRYP PFNGLDEPTHMASKPROC) (GLboolean flag);
typedef void (APIENTRYP PFNGLDISABLEPROC) (GLenum cap);
typedef void (APIENTRYP PFNGLENABLEPROC) (GLenum cap);
typedef void (APIENTRYP PFNGLFINISHPROC) (void);
typedef void (APIENTRYP PFNGLFLUSHPROC) (void);
typedef void (APIENTRYP PFNGLBLENDFUNCPROC) (GLenum sfactor, GLenum dfactor);
typedef void (APIENTRYP PFNGLLOGICOPPROC) (GLenum opcode);
typedef void (APIENTRYP PFNGLSTENCILFUNCPROC) (GLenum func, GLint ref, GLuint mask);
typedef void (APIENTRYP PFNGLSTENCILOPPROC) (GLenum fail, GLenum zfail, GLenum zpass);
typedef void (APIENTRYP PFNGLDEPTHFUNCPROC) (GLenum func);
typedef void (APIENTRYP PFNGLPIXELSTOREFPROC) (GLenum pname, GLfloat param);
typedef void (APIENTRYP PFNGLPIXELSTOREIPROC) (GLenum pname, GLint param);
typedef void (APIENTRYP PFNGLREADBUFFERPROC) (GLenum mode);
typedef void (APIENTRYP PFNGLREADPIXELSPROC) (GLint x, GLint y, GLsizei width, GLsizei height, GLenum format, GLenum type, void *pixels);
typedef void (APIENTRYP PFNGLGETBOOLEANVPROC) (GLenum pname, GLboolean *data);
typedef void (APIENTRYP PFNGLGETDOUBLEVPROC) (GLenum pname, GLdouble *data);
typedef GLenum (APIENTRYP PFNGLGETERRORPROC) (void);
typedef void (APIENTRYP PFNGLGETFLOATVPROC) (GLenum pname, GLfloat *data);
typedef void (APIENTRYP PFNGLGETINTEGERVPROC) (GLenum pname, GLint *data);
typedef const GLubyte *(APIENTRYP PFNGLGETSTRINGPROC) (GLenum name);
typedef void (APIENTRYP PFNGLGETTEXIMAGEPROC) (GLenum target, GLint level, GLenum format, GLenum type, void *pixels);
typedef void (APIENTRYP PFNGLGETTEXPARAMETERFVPROC) (GLenum target, GLenum pname, GLfloat *params);
typedef void (APIENTRYP PFNGLGETTEXPARAMETERIVPROC) (GLenum target, GLenum pname, GLint *params);
typedef void (APIENTRYP PFNGLGETTEXLEVELPARAMETERFVPROC) (GLenum target, GLint level, GLenum pname, GLfloat *params);
typedef void (APIENTRYP PFNGLGETTEXLEVELPARAMETERIVPROC) (GLenum target, GLint level, GLenum pname, GLint *params);
typedef GLboolean (APIENTRYP PFNGLISENABLEDPROC) (GLenum cap);
typedef void (APIENTRYP PFNGLDEPTHRANGEPROC) (GLdouble near, GLdouble far);
typedef void (APIENTRYP PFNGLVIEWPORTPROC) (GLint x, GLint y, GLsizei width, GLsizei height);

typedef float GLclampf;
typedef double GLclampd;
#define GL_DEPTH_BUFFER_BIT               0x00000100
#define GL_STENCIL_BUFFER_BIT             0x00000400
#define GL_COLOR_BUFFER_BIT               0x00004000
#define GL_FALSE                          0
#define GL_TRUE                           1
#define GL_POINTS                         0x0000
#define GL_LINES                          0x0001
#define GL_LINE_LOOP                      0x0002
#define GL_LINE_STRIP                     0x0003
#define GL_TRIANGLES                      0x0004
#define GL_TRIANGLE_STRIP                 0x0005
#define GL_TRIANGLE_FAN                   0x0006
#define GL_QUADS                          0x0007
#define GL_NEVER                          0x0200
#define GL_LESS                           0x0201
#define GL_EQUAL                          0x0202
#define GL_LEQUAL                         0x0203
#define GL_GREATER                        0x0204
#define GL_NOTEQUAL                       0x0205
#define GL_GEQUAL                         0x0206
#define GL_ALWAYS                         0x0207
#define GL_ZERO                           0
#define GL_ONE                            1
#define GL_SRC_COLOR                      0x0300
#define GL_ONE_MINUS_SRC_COLOR            0x0301
#define GL_SRC_ALPHA                      0x0302
#define GL_ONE_MINUS_SRC_ALPHA            0x0303
#define GL_DST_ALPHA                      0x0304
#define GL_ONE_MINUS_DST_ALPHA            0x0305
#define GL_DST_COLOR                      0x0306
#define GL_ONE_MINUS_DST_COLOR            0x0307
#define GL_SRC_ALPHA_SATURATE             0x0308
#define GL_NONE                           0
#define GL_FRONT_LEFT                     0x0400
#define GL_FRONT_RIGHT                    0x0401
#define GL_BACK_LEFT                      0x0402
#define GL_BACK_RIGHT                     0x0403
#define GL_FRONT                          0x0404
#define GL_BACK                           0x0405
#define GL_LEFT                           0x0406
#define GL_RIGHT                          0x0407
#define GL_FRONT_AND_BACK                 0x0408
#define GL_NO_ERROR                       0
#define GL_INVALID_ENUM                   0x0500
#define GL_INVALID_VALUE                  0x0501
#define GL_INVALID_OPERATION              0x0502
#define GL_OUT_OF_MEMORY                  0x0505
#define GL_CW                             0x0900
#define GL_CCW                            0x0901
#define GL_POINT_SIZE                     0x0B11
#define GL_POINT_SIZE_RANGE               0x0B12
#define GL_POINT_SIZE_GRANULARITY         0x0B13
#define GL_LINE_SMOOTH                    0x0B20
#define GL_LINE_WIDTH                     0x0B21
#define GL_LINE_WIDTH_RANGE               0x0B22
#define GL_LINE_WIDTH_GRANULARITY         0x0B23
#define GL_POLYGON_MODE                   0x0B40
#define GL_POLYGON_SMOOTH                 0x0B41
#define GL_CULL_FACE                      0x0B44
#define GL_CULL_FACE_MODE                 0x0B45
#define GL_FRONT_FACE                     0x0B46
#define GL_DEPTH_RANGE                    0x0B70
#define GL_DEPTH_TEST                     0x0B71
#define GL_DEPTH_WRITEMASK                0x0B72
#define GL_DEPTH_CLEAR_VALUE              0x0B73
#define GL_DEPTH_FUNC                     0x0B74
#define GL_STENCIL_TEST                   0x0B90
#define GL_STENCIL_CLEAR_VALUE            0x0B91
#define GL_STENCIL_FUNC                   0x0B92
#define GL_STENCIL_VALUE_MASK             0x0B93
#define GL_STENCIL_FAIL                   0x0B94
#define GL_STENCIL_PASS_DEPTH_FAIL        0x0B95
#define GL_STENCIL_PASS_DEPTH_PASS        0x0B96
#define GL_STENCIL_REF                    0x0B97
#define GL_STENCIL_WRITEMASK              0x0B98
#define GL_VIEWPORT                       0x0BA2
#define GL_DITHER                         0x0BD0
#define GL_BLEND_DST                      0x0BE0
#define GL_BLEND_SRC                      0x0BE1
#define GL_BLEND                          0x0BE2
#define GL_LOGIC_OP_MODE                  0x0BF0
#define GL_COLOR_LOGIC_OP                 0x0BF2
#define GL_DRAW_BUFFER                    0x0C01
#define GL_READ_BUFFER                    0x0C02
#define GL_SCISSOR_BOX                    0x0C10
#define GL_SCISSOR_TEST                   0x0C11
#define GL_COLOR_CLEAR_VALUE              0x0C22
#define GL_COLOR_WRITEMASK                0x0C23
#define GL_DOUBLEBUFFER                   0x0C32
#define GL_STEREO                         0x0C33
#define GL_LINE_SMOOTH_HINT               0x0C52
#define GL_POLYGON_SMOOTH_HINT            0x0C53
#define GL_UNPACK_SWAP_BYTES              0x0CF0
#define GL_UNPACK_LSB_FIRST               0x0CF1
#define GL_UNPACK_ROW_LENGTH              0x0CF2
#define GL_UNPACK_SKIP_ROWS               0x0CF3
#define GL_UNPACK_SKIP_PIXELS             0x0CF4
#define GL_UNPACK_ALIGNMENT               0x0CF5
#define GL_PACK_SWAP_BYTES                0x0D00
#define GL_PACK_LSB_FIRST                 0x0D01
#define GL_PACK_ROW_LENGTH                0x0D02
#define GL_PACK_SKIP_ROWS                 0x0D03
#define GL_PACK_SKIP_PIXELS               0x0D04
#define GL_PACK_ALIGNMENT                 0x0D05
#define GL_MAX_TEXTURE_SIZE               0x0D33
#define GL_MAX_VIEWPORT_DIMS              0x0D3A
#define GL_SUBPIXEL_BITS                  0x0D50
#define GL_TEXTURE_1D                     0x0DE0
#define GL_TEXTURE_2D                     0x0DE1
#define GL_POLYGON_OFFSET_UNITS           0x2A00
#define GL_POLYGON_OFFSET_POINT           0x2A01
#define GL_POLYGON_OFFSET_LINE            0x2A02
#define GL_POLYGON_OFFSET_FILL            0x8037
#define GL_POLYGON_OFFSET_FACTOR          0x8038
#define GL_TEXTURE_BINDING_1D             0x8068
#define GL_TEXTURE_BINDING_2D             0x8069
#define GL_TEXTURE_WIDTH                  0x1000
#define GL_TEXTURE_HEIGHT                 0x1001
#define GL_TEXTURE_INTERNAL_FORMAT        0x1003
#define GL_TEXTURE_BORDER_COLOR           0x1004
#define GL_TEXTURE_RED_SIZE               0x805C
#define GL_TEXTURE_GREEN_SIZE             0x805D
#define GL_TEXTURE_BLUE_SIZE              0x805E
#define GL_TEXTURE_ALPHA_SIZE             0x805F
#define GL_DONT_CARE                      0x1100
#define GL_FASTEST                        0x1101
#define GL_NICEST                         0x1102
#define GL_BYTE                           0x1400
#define GL_UNSIGNED_BYTE                  0x1401
#define GL_SHORT                          0x1402
#define GL_UNSIGNED_SHORT                 0x1403
#define GL_INT                            0x1404
#define GL_UNSIGNED_INT                   0x1405
#define GL_FLOAT                          0x1406
#define GL_DOUBLE                         0x140A
#define GL_STACK_OVERFLOW                 0x0503
#define GL_STACK_UNDERFLOW                0x0504
#define GL_CLEAR                          0x1500
#define GL_AND                            0x1501
#define GL_AND_REVERSE                    0x1502
#define GL_COPY                           0x1503
#define GL_AND_INVERTED                   0x1504
#define GL_NOOP                           0x1505
#define GL_XOR                            0x1506
#define GL_OR                             0x1507
#define GL_NOR                            0x1508
#define GL_EQUIV                          0x1509
#define GL_INVERT                         0x150A
#define GL_OR_REVERSE                     0x150B
#define GL_COPY_INVERTED                  0x150C
#define GL_OR_INVERTED                    0x150D
#define GL_NAND                           0x150E
#define GL_SET                            0x150F
#define GL_TEXTURE                        0x1702
#define GL_COLOR                          0x1800
#define GL_DEPTH                          0x1801
#define GL_STENCIL                        0x1802
#define GL_STENCIL_INDEX                  0x1901
#define GL_DEPTH_COMPONENT                0x1902
#define GL_RED                            0x1903
#define GL_GREEN                          0x1904
#define GL_BLUE                           0x1905
#define GL_ALPHA                          0x1906
#define GL_RGB                            0x1907
#define GL_RGBA                           0x1908
#define GL_POINT                          0x1B00
#define GL_LINE                           0x1B01
#define GL_FILL                           0x1B02
#define GL_KEEP                           0x1E00
#define GL_REPLACE                        0x1E01
#define GL_INCR                           0x1E02
#define GL_DECR                           0x1E03
#define GL_VENDOR                         0x1F00
#define GL_RENDERER                       0x1F01
#define GL_VERSION                        0x1F02
#define GL_EXTENSIONS                     0x1F03
#define GL_NEAREST                        0x2600
#define GL_LINEAR                         0x2601
#define GL_NEAREST_MIPMAP_NEAREST         0x2700
#define GL_LINEAR_MIPMAP_NEAREST          0x2701
#define GL_NEAREST_MIPMAP_LINEAR          0x2702
#define GL_LINEAR_MIPMAP_LINEAR           0x2703
#define GL_TEXTURE_MAG_FILTER             0x2800
#define GL_TEXTURE_MIN_FILTER             0x2801
#define GL_TEXTURE_WRAP_S                 0x2802
#define GL_TEXTURE_WRAP_T                 0x2803
#define GL_PROXY_TEXTURE_1D               0x8063
#define GL_PROXY_TEXTURE_2D               0x8064
#define GL_REPEAT                         0x2901
#define GL_R3_G3_B2                       0x2A10
#define GL_RGB4                           0x804F
#define GL_RGB5                           0x8050
#define GL_RGB8                           0x8051
#define GL_RGB10                          0x8052
#define GL_RGB12                          0x8053
#define GL_RGB16                          0x8054
#define GL_RGBA2                          0x8055
#define GL_RGBA4                          0x8056
#define GL_RGB5_A1                        0x8057
#define GL_RGBA8                          0x8058
#define GL_RGB10_A2                       0x8059
#define GL_RGBA12                         0x805A
#define GL_RGBA16                         0x805B
#define GL_VERTEX_ARRAY                   0x8074
typedef void (APIENTRYP PFNGLDRAWARRAYSPROC) (GLenum mode, GLint first, GLsizei count);
typedef void (APIENTRYP PFNGLDRAWELEMENTSPROC) (GLenum mode, GLsizei count, GLenum type, const void *indices);
typedef void (APIENTRYP PFNGLGETPOINTERVPROC) (GLenum pname, void **params);
typedef void (APIENTRYP PFNGLPOLYGONOFFSETPROC) (GLfloat factor, GLfloat units);
typedef void (APIENTRYP PFNGLCOPYTEXIMAGE1DPROC) (GLenum target, GLint level, GLenum internalformat, GLint x, GLint y, GLsizei width, GLint border);
typedef void (APIENTRYP PFNGLCOPYTEXIMAGE2DPROC) (GLenum target, GLint level, GLenum internalformat, GLint x, GLint y, GLsizei width, GLsizei height, GLint border);
typedef void (APIENTRYP PFNGLCOPYTEXSUBIMAGE1DPROC) (GLenum target, GLint level, GLint xoffset, GLint x, GLint y, GLsizei width);
typedef void (APIENTRYP PFNGLCOPYTEXSUBIMAGE2DPROC) (GLenum target, GLint level, GLint xoffset, GLint yoffset, GLint x, GLint y, GLsizei width, GLsizei height);
typedef void (APIENTRYP PFNGLTEXSUBIMAGE1DPROC) (GLenum target, GLint level, GLint xoffset, GLsizei width, GLenum format, GLenum type, const void *pixels);
typedef void (APIENTRYP PFNGLTEXSUBIMAGE2DPROC) (GLenum target, GLint level, GLint xoffset, GLint yoffset, GLsizei width, GLsizei height, GLenum format, GLenum type, const void *pixels);
typedef void (APIENTRYP PFNGLBINDTEXTUREPROC) (GLenum target, GLuint texture);
typedef void (APIENTRYP PFNGLDELETETEXTURESPROC) (GLsizei n, const GLuint *textures);
typedef void (APIENTRYP PFNGLGENTEXTURESPROC) (GLsizei n, GLuint *textures);
typedef GLboolean (APIENTRYP PFNGLISTEXTUREPROC) (GLuint texture);

#define GL_UNSIGNED_BYTE_3_3_2            0x8032
#define GL_UNSIGNED_SHORT_4_4_4_4         0x8033
#define GL_UNSIGNED_SHORT_5_5_5_1         0x8034
#define GL_UNSIGNED_INT_8_8_8_8           0x8035
#define GL_UNSIGNED_INT_10_10_10_2        0x8036
#define GL_TEXTURE_BINDING_3D             0x806A
#define GL_PACK_SKIP_IMAGES               0x806B
#define GL_PACK_IMAGE_HEIGHT              0x806C
#define GL_UNPACK_SKIP_IMAGES             0x806D
#define GL_UNPACK_IMAGE_HEIGHT            0x806E
#define GL_TEXTURE_3D                     0x806F
#define GL_PROXY_TEXTURE_3D               0x8070
#define GL_TEXTURE_DEPTH                  0x8071
#define GL_TEXTURE_WRAP_R                 0x8072
#define GL_MAX_3D_TEXTURE_SIZE            0x8073
#define GL_UNSIGNED_BYTE_2_3_3_REV        0x8362
#define GL_UNSIGNED_SHORT_5_6_5           0x8363
#define GL_UNSIGNED_SHORT_5_6_5_REV       0x8364
#define GL_UNSIGNED_SHORT_4_4_4_4_REV     0x8365
#define GL_UNSIGNED_SHORT_1_5_5_5_REV     0x8366
#define GL_UNSIGNED_INT_8_8_8_8_REV       0x8367
#define GL_UNSIGNED_INT_2_10_10_10_REV    0x8368
#define GL_BGR                            0x80E0
#define GL_BGRA                           0x80E1
#define GL_MAX_ELEMENTS_VERTICES          0x80E8
#define GL_MAX_ELEMENTS_INDICES           0x80E9
#define GL_CLAMP_TO_EDGE                  0x812F
#define GL_TEXTURE_MIN_LOD                0x813A
#define GL_TEXTURE_MAX_LOD                0x813B
#define GL_TEXTURE_BASE_LEVEL             0x813C
#define GL_TEXTURE_MAX_LEVEL              0x813D
#define GL_SMOOTH_POINT_SIZE_RANGE        0x0B12
#define GL_SMOOTH_POINT_SIZE_GRANULARITY  0x0B13
#define GL_SMOOTH_LINE_WIDTH_RANGE        0x0B22
#define GL_SMOOTH_LINE_WIDTH_GRANULARITY  0x0B23
#define GL_ALIASED_LINE_WIDTH_RANGE       0x846E
typedef void (APIENTRYP PFNGLDRAWRANGEELEMENTSPROC) (GLenum mode, GLuint start, GLuint end, GLsizei count, GLenum type, const void *indices);
typedef void (APIENTRYP PFNGLTEXIMAGE3DPROC) (GLenum target, GLint level, GLint internalformat, GLsizei width, GLsizei height, GLsizei depth, GLint border, GLenum format, GLenum type, const void *pixels);
typedef void (APIENTRYP PFNGLTEXSUBIMAGE3DPROC) (GLenum target, GLint level, GLint xoffset, GLint yoffset, GLint zoffset, GLsizei width, GLsizei height, GLsizei depth, GLenum format, GLenum type, const void *pixels);
typedef void (APIENTRYP PFNGLCOPYTEXSUBIMAGE3DPROC) (GLenum target, GLint level, GLint xoffset, GLint yoffset, GLint zoffset, GLint x, GLint y, GLsizei width, GLsizei height);

#define GL_TEXTURE0                       0x84C0
#define GL_TEXTURE1                       0x84C1
#define GL_TEXTURE2                       0x84C2
#define GL_TEXTURE3                       0x84C3
#define GL_TEXTURE4                       0x84C4
#define GL_TEXTURE5                       0x84C5
#define GL_TEXTURE6                       0x84C6
#define GL_TEXTURE7                       0x84C7
#define GL_TEXTURE8                       0x84C8
#define GL_TEXTURE9                       0x84C9
#define GL_TEXTURE10                      0x84CA
#define GL_TEXTURE11                      0x84CB
#define GL_TEXTURE12                      0x84CC
#define GL_TEXTURE13                      0x84CD
#define GL_TEXTURE14                      0x84CE
#define GL_TEXTURE15                      0x84CF
#define GL_TEXTURE16                      0x84D0
#define GL_TEXTURE17                      0x84D1
#define GL_TEXTURE18                      0x84D2
#define GL_TEXTURE19                      0x84D3
#define GL_TEXTURE20                      0x84D4
#define GL_TEXTURE21                      0x84D5
#define GL_TEXTURE22                      0x84D6
#define GL_TEXTURE23                      0x84D7
#define GL_TEXTURE24                      0x84D8
#define GL_TEXTURE25                      0x84D9
#define GL_TEXTURE26                      0x84DA
#define GL_TEXTURE27                      0x84DB
#define GL_TEXTURE28                      0x84DC
#define GL_TEXTURE29                      0x84DD
#define GL_TEXTURE30                      0x84DE
#define GL_TEXTURE31                      0x84DF
#define GL_ACTIVE_TEXTURE                 0x84E0
#define GL_MULTISAMPLE                    0x809D
#define GL_SAMPLE_ALPHA_TO_COVERAGE       0x809E
#define GL_SAMPLE_ALPHA_TO_ONE            0x809F
#define GL_SAMPLE_COVERAGE                0x80A0
#define GL_SAMPLE_BUFFERS                 0x80A8
#define GL_SAMPLES                        0x80A9
#define GL_SAMPLE_COVERAGE_VALUE          0x80AA
#define GL_SAMPLE_COVERAGE_INVERT         0x80AB
#define GL_TEXTURE_CUBE_MAP               0x8513
#define GL_TEXTURE_BINDING_CUBE_MAP       0x8514
#define GL_TEXTURE_CUBE_MAP_POSITIVE_X    0x8515
#define GL_TEXTURE_CUBE_MAP_NEGATIVE_X    0x8516
#define GL_TEXTURE_CUBE_MAP_POSITIVE_Y    0x8517
#define GL_TEXTURE_CUBE_MAP_NEGATIVE_Y    0x8518
#define GL_TEXTURE_CUBE_MAP_POSITIVE_Z    0x8519
#define GL_TEXTURE_CUBE_MAP_NEGATIVE_Z    0x851A
#define GL_PROXY_TEXTURE_CUBE_MAP         0x851B
#define GL_MAX_CUBE_MAP_TEXTURE_SIZE      0x851C
#define GL_COMPRESSED_RGB                 0x84ED
#define GL_COMPRESSED_RGBA                0x84EE
#define GL_TEXTURE_COMPRESSION_HINT       0x84EF
#define GL_TEXTURE_COMPRESSED_IMAGE_SIZE  0x86A0
#define GL_TEXTURE_COMPRESSED             0x86A1
#define GL_NUM_COMPRESSED_TEXTURE_FORMATS 0x86A2
#define GL_COMPRESSED_TEXTURE_FORMATS     0x86A3
#define GL_CLAMP_TO_BORDER                0x812D
typedef void (APIENTRYP PFNGLACTIVETEXTUREPROC) (GLenum texture);
typedef void (APIENTRYP PFNGLSAMPLECOVERAGEPROC) (GLfloat value, GLboolean invert);
typedef void (APIENTRYP PFNGLCOMPRESSEDTEXIMAGE3DPROC) (GLenum target, GLint level, GLenum internalformat, GLsizei width, GLsizei height, GLsizei depth, GLint border, GLsizei imageSize, const void *data);
typedef void (APIENTRYP PFNGLCOMPRESSEDTEXIMAGE2DPROC) (GLenum target, GLint level, GLenum internalformat, GLsizei width, GLsizei height, GLint border, GLsizei imageSize, const void *data);
typedef void (APIENTRYP PFNGLCOMPRESSEDTEXIMAGE1DPROC) (GLenum target, GLint level, GLenum internalformat, GLsizei width, GLint border, GLsizei imageSize, const void *data);
typedef void (APIENTRYP PFNGLCOMPRESSEDTEXSUBIMAGE3DPROC) (GLenum target, GLint level, GLint xoffset, GLint yoffset, GLint zoffset, GLsizei width, GLsizei height, GLsizei depth, GLenum format, GLsizei imageSize, const void *data);
typedef void (APIENTRYP PFNGLCOMPRESSEDTEXSUBIMAGE2DPROC) (GLenum target, GLint level, GLint xoffset, GLint yoffset, GLsizei width, GLsizei height, GLenum format, GLsizei imageSize, const void *data);
typedef void (APIENTRYP PFNGLCOMPRESSEDTEXSUBIMAGE1DPROC) (GLenum target, GLint level, GLint xoffset, GLsizei width, GLenum format, GLsizei imageSize, const void *data);
typedef void (APIENTRYP PFNGLGETCOMPRESSEDTEXIMAGEPROC) (GLenum target, GLint level, void *img);

#define GL_BLEND_DST_RGB                  0x80C8
#define GL_BLEND_SRC_RGB                  0x80C9
#define GL_BLEND_DST_ALPHA                0x80CA
#define GL_BLEND_SRC_ALPHA                0x80CB
#define GL_POINT_FADE_THRESHOLD_SIZE      0x8128
#define GL_DEPTH_COMPONENT16              0x81A5
#define GL_DEPTH_COMPONENT24              0x81A6
#define GL_DEPTH_COMPONENT32              0x81A7
#define GL_MIRRORED_REPEAT                0x8370
#define GL_MAX_TEXTURE_LOD_BIAS           0x84FD
#define GL_TEXTURE_LOD_BIAS               0x8501
#define GL_INCR_WRAP                      0x8507
#define GL_DECR_WRAP                      0x8508
#define GL_TEXTURE_DEPTH_SIZE             0x884A
#define GL_TEXTURE_COMPARE_MODE           0x884C
#define GL_TEXTURE_COMPARE_FUNC           0x884D
#define GL_FUNC_ADD                       0x8006
#define GL_FUNC_SUBTRACT                  0x800A
#define GL_FUNC_REVERSE_SUBTRACT          0x800B
#define GL_MIN                            0x8007
#define GL_MAX                            0x8008
#define GL_CONSTANT_COLOR                 0x8001
#define GL_ONE_MINUS_CONSTANT_COLOR       0x8002
#define GL_CONSTANT_ALPHA                 0x8003
#define GL_ONE_MINUS_CONSTANT_ALPHA       0x8004
typedef void (APIENTRYP PFNGLBLENDFUNCSEPARATEPROC) (GLenum sfactorRGB, GLenum dfactorRGB, GLenum sfactorAlpha, GLenum dfactorAlpha);
typedef void (APIENTRYP PFNGLMULTIDRAWARRAYSPROC) (GLenum mode, const GLint *first, const GLsizei *count, GLsizei drawcount);
typedef void (APIENTRYP PFNGLMULTIDRAWELEMENTSPROC) (GLenum mode, const GLsizei *count, GLenum type, const void *const*indices, GLsizei drawcount);
typedef void (APIENTRYP PFNGLPOINTPARAMETERFPROC) (GLenum pname, GLfloat param);
typedef void (APIENTRYP PFNGLPOINTPARAMETERFVPROC) (GLenum pname, const GLfloat *params);
typedef void (APIENTRYP PFNGLPOINTPARAMETERIPROC) (GLenum pname, GLint param);
typedef void (APIENTRYP PFNGLPOINTPARAMETERIVPROC) (GLenum pname, const GLint *params);
typedef void (APIENTRYP PFNGLBLENDCOLORPROC) (GLfloat red, GLfloat green, GLfloat blue, GLfloat alpha);
typedef void (APIENTRYP PFNGLBLENDEQUATIONPROC) (GLenum mode);

typedef ptrdiff_t GLsizeiptr;
typedef ptrdiff_t GLintptr;
#define GL_BUFFER_SIZE                    0x8764
#define GL_BUFFER_USAGE                   0x8765
#define GL_QUERY_COUNTER_BITS             0x8864
#define GL_CURRENT_QUERY                  0x8865
#define GL_QUERY_RESULT                   0x8866
#define GL_QUERY_RESULT_AVAILABLE         0x8867
#define GL_ARRAY_BUFFER                   0x8892
#define GL_ELEMENT_ARRAY_BUFFER           0x8893
#define GL_ARRAY_BUFFER_BINDING           0x8894
#define GL_ELEMENT_ARRAY_BUFFER_BINDING   0x8895
#define GL_VERTEX_ATTRIB_ARRAY_BUFFER_BINDING 0x889F
#define GL_READ_ONLY                      0x88B8
#define GL_WRITE_ONLY                     0x88B9
#define GL_READ_WRITE                     0x88BA
#define GL_BUFFER_ACCESS                  0x88BB
#define GL_BUFFER_MAPPED                  0x88BC
#define GL_BUFFER_MAP_POINTER             0x88BD
#define GL_STREAM_DRAW                    0x88E0
#define GL_STREAM_READ                    0x88E1
#define GL_STREAM_COPY                    0x88E2
#define GL_STATIC_DRAW                    0x88E4
#define GL_STATIC_READ                    0x88E5
#define GL_STATIC_COPY                    0x88E6
#define GL_DYNAMIC_DRAW                   0x88E8
#define GL_DYNAMIC_READ                   0x88E9
#define GL_DYNAMIC_COPY                   0x88EA
#define GL_SAMPLES_PASSED                 0x8914
#define GL_SRC1_ALPHA                     0x8589
typedef void (APIENTRYP PFNGLGENQUERIESPROC) (GLsizei n, GLuint *ids);
typedef void (APIENTRYP PFNGLDELETEQUERIESPROC) (GLsizei n, const GLuint *ids);
typedef GLboolean (APIENTRYP PFNGLISQUERYPROC) (GLuint id);
typedef void (APIENTRYP PFNGLBEGINQUERYPROC) (GLenum target, GLuint id);
typedef void (APIENTRYP PFNGLENDQUERYPROC) (GLenum target);
typedef void (APIENTRYP PFNGLGETQUERYIVPROC) (GLenum target, GLenum pname, GLint *params);
typedef void (APIENTRYP PFNGLGETQUERYOBJECTIVPROC) (GLuint id, GLenum pname, GLint *params);
typedef void (APIENTRYP PFNGLGETQUERYOBJECTUIVPROC) (GLuint id, GLenum pname, GLuint *params);
typedef void (APIENTRYP PFNGLBINDBUFFERPROC) (GLenum target, GLuint buffer);
typedef void (APIENTRYP PFNGLDELETEBUFFERSPROC) (GLsizei n, const GLuint *buffers);
typedef void (APIENTRYP PFNGLGENBUFFERSPROC) (GLsizei n, GLuint *buffers);
typedef GLboolean (APIENTRYP PFNGLISBUFFERPROC) (GLuint buffer);
typedef void (APIENTRYP PFNGLBUFFERDATAPROC) (GLenum target, GLsizeiptr size, const void *data, GLenum usage);
typedef void (APIENTRYP PFNGLBUFFERSUBDATAPROC) (GLenum target, GLintptr offset, GLsizeiptr size, const void *data);
typedef void (APIENTRYP PFNGLGETBUFFERSUBDATAPROC) (GLenum target, GLintptr offset, GLsizeiptr size, void *data);
typedef void *(APIENTRYP PFNGLMAPBUFFERPROC) (GLenum target, GLenum access);
typedef GLboolean (APIENTRYP PFNGLUNMAPBUFFERPROC) (GLenum target);
typedef void (APIENTRYP PFNGLGETBUFFERPARAMETERIVPROC) (GLenum target, GLenum pname, GLint *params);
typedef void (APIENTRYP PFNGLGETBUFFERPOINTERVPROC) (GLenum target, GLenum pname, void **params);

typedef char GLchar;
typedef short GLshort;
typedef signed char GLbyte;
typedef unsigned short GLushort;
#define GL_BLEND_EQUATION_RGB             0x8009
#define GL_VERTEX_ATTRIB_ARRAY_ENABLED    0x8622
#define GL_VERTEX_ATTRIB_ARRAY_SIZE       0x8623
#define GL_VERTEX_ATTRIB_ARRAY_STRIDE     0x8624
#define GL_VERTEX_ATTRIB_ARRAY_TYPE       0x8625
#define GL_CURRENT_VERTEX_ATTRIB          0x8626
#define GL_VERTEX_PROGRAM_POINT_SIZE      0x8642
#define GL_VERTEX_ATTRIB_ARRAY_POINTER    0x8645
#define GL_STENCIL_BACK_FUNC              0x8800
#define GL_STENCIL_BACK_FAIL              0x8801
#define GL_STENCIL_BACK_PASS_DEPTH_FAIL   0x8802
#define GL_STENCIL_BACK_PASS_DEPTH_PASS   0x8803
#define GL_MAX_DRAW_BUFFERS               0x8824
#define GL_DRAW_BUFFER0                   0x8825
#define GL_DRAW_BUFFER1                   0x8826
#define GL_DRAW_BUFFER2                   0x8827
#define GL_DRAW_BUFFER3                   0x8828
#define GL_DRAW_BUFFER4                   0x8829
#define GL_DRAW_BUFFER5                   0x882A
#define GL_DRAW_BUFFER6                   0x882B
#define GL_DRAW_BUFFER7                   0x882C
#define GL_DRAW_BUFFER8                   0x882D
#define GL_DRAW_BUFFER9                   0x882E
#define GL_DRAW_BUFFER10                  0x882F
#define GL_DRAW_BUFFER11                  0x8830
#define GL_DRAW_BUFFER12                  0x8831
#define GL_DRAW_BUFFER13                  0x8832
#define GL_DRAW_BUFFER14                  0x8833
#define GL_DRAW_BUFFER15                  0x8834
#define GL_BLEND_EQUATION_ALPHA           0x883D
#define GL_MAX_VERTEX_ATTRIBS             0x8869
#define GL_VERTEX_ATTRIB_ARRAY_NORMALIZED 0x886A
#define GL_MAX_TEXTURE_IMAGE_UNITS        0x8872
#define GL_FRAGMENT_SHADER                0x8B30
#define GL_VERTEX_SHADER                  0x8B31
#define GL_MAX_FRAGMENT_UNIFORM_COMPONENTS 0x8B49
#define GL_MAX_VERTEX_UNIFORM_COMPONENTS  0x8B4A
#define GL_MAX_VARYING_FLOATS             0x8B4B
#define GL_MAX_VERTEX_TEXTURE_IMAGE_UNITS 0x8B4C
#define GL_MAX_COMBINED_TEXTURE_IMAGE_UNITS 0x8B4D
#define GL_SHADER_TYPE                    0x8B4F
#define GL_FLOAT_VEC2                     0x8B50
#define GL_FLOAT_VEC3                     0x8B51
#define GL_FLOAT_VEC4                     0x8B52
#define GL_INT_VEC2                       0x8B53
#define GL_INT_VEC3                       0x8B54
#define GL_INT_VEC4                       0x8B55
#define GL_BOOL                           0x8B56
#define GL_BOOL_VEC2                      0x8B57
#define GL_BOOL_VEC3                      0x8B58
#define GL_BOOL_VEC4                      0x8B59
#define GL_FLOAT_MAT2                     0x8B5A
#define GL_FLOAT_MAT3                     0x8B5B
#define GL_FLOAT_MAT4                     0x8B5C
#define GL_SAMPLER_1D                     0x8B5D
#define GL_SAMPLER_2D                     0x8B5E
#define GL_SAMPLER_3D                     0x8B5F
#define GL_SAMPLER_CUBE                   0x8B60
#define GL_SAMPLER_1D_SHADOW              0x8B61
#define GL_SAMPLER_2D_SHADOW              0x8B62
#define GL_DELETE_STATUS                  0x8B80
#define GL_COMPILE_STATUS                 0x8B81
#define GL_LINK_STATUS                    0x8B82
#define GL_VALIDATE_STATUS                0x8B83
#define GL_INFO_LOG_LENGTH                0x8B84
#define GL_ATTACHED_SHADERS               0x8B85
#define GL_ACTIVE_UNIFORMS                0x8B86
#define GL_ACTIVE_UNIFORM_MAX_LENGTH      0x8B87
#define GL_SHADER_SOURCE_LENGTH           0x8B88
#define GL_ACTIVE_ATTRIBUTES              0x8B89
#define GL_ACTIVE_ATTRIBUTE_MAX_LENGTH    0x8B8A
#define GL_FRAGMENT_SHADER_DERIVATIVE_HINT 0x8B8B
#define GL_SHADING_LANGUAGE_VERSION       0x8B8C
#define GL_CURRENT_PROGRAM                0x8B8D
#define GL_POINT_SPRITE_COORD_ORIGIN      0x8CA0
#define GL_LOWER_LEFT                     0x8CA1
#define GL_UPPER_LEFT                     0x8CA2
#define GL_STENCIL_BACK_REF               0x8CA3
#define GL_STENCIL_BACK_VALUE_MASK        0x8CA4
#define GL_STENCIL_BACK_WRITEMASK         0x8CA5
typedef void (APIENTRYP PFNGLBLENDEQUATIONSEPARATEPROC) (GLenum modeRGB, GLenum modeAlpha);
typedef void (APIENTRYP PFNGLDRAWBUFFERSPROC) (GLsizei n, const GLenum *bufs);
typedef void (APIENTRYP PFNGLSTENCILOPSEPARATEPROC) (GLenum face, GLenum sfail, GLenum dpfail, GLenum dppass);
typedef void (APIENTRYP PFNGLSTENCILFUNCSEPARATEPROC) (GLenum face, GLenum func, GLint ref, GLuint mask);
typedef void (APIENTRYP PFNGLSTENCILMASKSEPARATEPROC) (GLenum face, GLuint mask);
typedef void (APIENTRYP PFNGLATTACHSHADERPROC) (GLuint program, GLuint shader);
typedef void (APIENTRYP PFNGLBINDATTRIBLOCATIONPROC) (GLuint program, GLuint index, const GLchar *name);
typedef void (APIENTRYP PFNGLCOMPILESHADERPROC) (GLuint shader);
typedef GLuint (APIENTRYP PFNGLCREATEPROGRAMPROC) (void);
typedef GLuint (APIENTRYP PFNGLCREATESHADERPROC) (GLenum type);
typedef void (APIENTRYP PFNGLDELETEPROGRAMPROC) (GLuint program);
typedef void (APIENTRYP PFNGLDELETESHADERPROC) (GLuint shader);
typedef void (APIENTRYP PFNGLDETACHSHADERPROC) (GLuint program, GLuint shader);
typedef void (APIENTRYP PFNGLDISABLEVERTEXATTRIBARRAYPROC) (GLuint index);
typedef void (APIENTRYP PFNGLENABLEVERTEXATTRIBARRAYPROC) (GLuint index);
typedef void (APIENTRYP PFNGLGETACTIVEATTRIBPROC) (GLuint program, GLuint index, GLsizei bufSize, GLsizei *length, GLint *size, GLenum *type, GLchar *name);
typedef void (APIENTRYP PFNGLGETACTIVEUNIFORMPROC) (GLuint program, GLuint index, GLsizei bufSize, GLsizei *length, GLint *size, GLenum *type, GLchar *name);
typedef void (APIENTRYP PFNGLGETATTACHEDSHADERSPROC) (GLuint program, GLsizei maxCount, GLsizei *count, GLuint *shaders);
typedef GLint (APIENTRYP PFNGLGETATTRIBLOCATIONPROC) (GLuint program, const GLchar *name);
typedef void (APIENTRYP PFNGLGETPROGRAMIVPROC) (GLuint program, GLenum pname, GLint *params);
typedef void (APIENTRYP PFNGLGETPROGRAMINFOLOGPROC) (GLuint program, GLsizei bufSize, GLsizei *length, GLchar *infoLog);
typedef void (APIENTRYP PFNGLGETSHADERIVPROC) (GLuint shader, GLenum pname, GLint *params);
typedef void (APIENTRYP PFNGLGETSHADERINFOLOGPROC) (GLuint shader, GLsizei bufSize, GLsizei *length, GLchar *infoLog);
typedef void (APIENTRYP PFNGLGETSHADERSOURCEPROC) (GLuint shader, GLsizei bufSize, GLsizei *length, GLchar *source);
typedef GLint (APIENTRYP PFNGLGETUNIFORMLOCATIONPROC) (GLuint program, const GLchar *name);
typedef void (APIENTRYP PFNGLGETUNIFORMFVPROC) (GLuint program, GLint location, GLfloat *params);
typedef void (APIENTRYP PFNGLGETUNIFORMIVPROC) (GLuint program, GLint location, GLint *params);
typedef void (APIENTRYP PFNGLGETVERTEXATTRIBDVPROC) (GLuint index, GLenum pname, GLdouble *params);
typedef void (APIENTRYP PFNGLGETVERTEXATTRIBFVPROC) (GLuint index, GLenum pname, GLfloat *params);
typedef void (APIENTRYP PFNGLGETVERTEXATTRIBIVPROC) (GLuint index, GLenum pname, GLint *params);
typedef void (APIENTRYP PFNGLGETVERTEXATTRIBPOINTERVPROC) (GLuint index, GLenum pname, void **pointer);
typedef GLboolean (APIENTRYP PFNGLISPROGRAMPROC) (GLuint program);
typedef GLboolean (APIENTRYP PFNGLISSHADERPROC) (GLuint shader);
typedef void (APIENTRYP PFNGLLINKPROGRAMPROC) (GLuint program);
typedef void (APIENTRYP PFNGLSHADERSOURCEPROC) (GLuint shader, GLsizei count, const GLchar *const*string, const GLint *length);
typedef void (APIENTRYP PFNGLUSEPROGRAMPROC) (GLuint program);
typedef void (APIENTRYP PFNGLUNIFORM1FPROC) (GLint location, GLfloat v0);
typedef void (APIENTRYP PFNGLUNIFORM2FPROC) (GLint location, GLfloat v0, GLfloat v1);
typedef void (APIENTRYP PFNGLUNIFORM3FPROC) (GLint location, GLfloat v0, GLfloat v1, GLfloat v2);
typedef void (APIENTRYP PFNGLUNIFORM4FPROC) (GLint location, GLfloat v0, GLfloat v1, GLfloat v2, GLfloat v3);
typedef void (APIENTRYP PFNGLUNIFORM1IPROC) (GLint location, GLint v0);
typedef void (APIENTRYP PFNGLUNIFORM2IPROC) (GLint location, GLint v0, GLint v1);
typedef void (APIENTRYP PFNGLUNIFORM3IPROC) (GLint location, GLint v0, GLint v1, GLint v2);
typedef void (APIENTRYP PFNGLUNIFORM4IPROC) (GLint location, GLint v0, GLint v1, GLint v2, GLint v3);
typedef void (APIENTRYP PFNGLUNIFORM1FVPROC) (GLint location, GLsizei count, const GLfloat *value);
typedef void (APIENTRYP PFNGLUNIFORM2FVPROC) (GLint location, GLsizei count, const GLfloat *value);
typedef void (APIENTRYP PFNGLUNIFORM3FVPROC) (GLint location, GLsizei count, const GLfloat *value);
typedef void (APIENTRYP PFNGLUNIFORM4FVPROC) (GLint location, GLsizei count, const GLfloat *value);
typedef void (APIENTRYP PFNGLUNIFORM1IVPROC) (GLint location, GLsizei count, const GLint *value);
typedef void (APIENTRYP PFNGLUNIFORM2IVPROC) (GLint location, GLsizei count, const GLint *value);
typedef void (APIENTRYP PFNGLUNIFORM3IVPROC) (GLint location, GLsizei count, const GLint *value);
typedef void (APIENTRYP PFNGLUNIFORM4IVPROC) (GLint location, GLsizei count, const GLint *value);
typedef void (APIENTRYP PFNGLUNIFORMMATRIX2FVPROC) (GLint location, GLsizei count, GLboolean transpose, const GLfloat *value);
typedef void (APIENTRYP PFNGLUNIFORMMATRIX3FVPROC) (GLint location, GLsizei count, GLboolean transpose, const GLfloat *value);
typedef void (APIENTRYP PFNGLUNIFORMMATRIX4FVPROC) (GLint location, GLsizei count, GLboolean transpose, const GLfloat *value);
typedef void (APIENTRYP PFNGLVALIDATEPROGRAMPROC) (GLuint program);
typedef void (APIENTRYP PFNGLVERTEXATTRIB1DPROC) (GLuint index, GLdouble x);
typedef void (APIENTRYP PFNGLVERTEXATTRIB1DVPROC) (GLuint index, const GLdouble *v);
typedef void (APIENTRYP PFNGLVERTEXATTRIB1FPROC) (GLuint index, GLfloat x);
typedef void (APIENTRYP PFNGLVERTEXATTRIB1FVPROC) (GLuint index, const GLfloat *v);
typedef void (APIENTRYP PFNGLVERTEXATTRIB1SPROC) (GLuint index, GLshort x);
typedef void (APIENTRYP PFNGLVERTEXATTRIB1SVPROC) (GLuint index, const GLshort *v);
typedef void (APIENTRYP PFNGLVERTEXATTRIB2DPROC) (GLuint index, GLdouble x, GLdouble y);
typedef void (APIENTRYP PFNGLVERTEXATTRIB2DVPROC) (GLuint index, const GLdouble *v);
typedef void (APIENTRYP PFNGLVERTEXATTRIB2FPROC) (GLuint index, GLfloat x, GLfloat y);
typedef void (APIENTRYP PFNGLVERTEXATTRIB2FVPROC) (GLuint index, const GLfloat *v);
typedef void (APIENTRYP PFNGLVERTEXATTRIB2SPROC) (GLuint index, GLshort x, GLshort y);
typedef void (APIENTRYP PFNGLVERTEXATTRIB2SVPROC) (GLuint index, const GLshort *v);
typedef void (APIENTRYP PFNGLVERTEXATTRIB3DPROC) (GLuint index, GLdouble x, GLdouble y, GLdouble z);
typedef void (APIENTRYP PFNGLVERTEXATTRIB3DVPROC) (GLuint index, const GLdouble *v);
typedef void (APIENTRYP PFNGLVERTEXATTRIB3FPROC) (GLuint index, GLfloat x, GLfloat y, GLfloat z);
typedef void (APIENTRYP PFNGLVERTEXATTRIB3FVPROC) (GLuint index, const GLfloat *v);
typedef void (APIENTRYP PFNGLVERTEXATTRIB3SPROC) (GLuint index, GLshort x, GLshort y, GLshort z);
typedef void (APIENTRYP PFNGLVERTEXATTRIB3SVPROC) (GLuint index, const GLshort *v);
typedef void (APIENTRYP PFNGLVERTEXATTRIB4NBVPROC) (GLuint index, const GLbyte *v);
typedef void (APIENTRYP PFNGLVERTEXATTRIB4NIVPROC) (GLuint index, const GLint *v);
typedef void (APIENTRYP PFNGLVERTEXATTRIB4NSVPROC) (GLuint index, const GLshort *v);
typedef void (APIENTRYP PFNGLVERTEXATTRIB4NUBPROC) (GLuint index, GLubyte x, GLubyte y, GLubyte z, GLubyte w);
typedef void (APIENTRYP PFNGLVERTEXATTRIB4NUBVPROC) (GLuint index, const GLubyte *v);
typedef void (APIENTRYP PFNGLVERTEXATTRIB4NUIVPROC) (GLuint index, const GLuint *v);
typedef void (APIENTRYP PFNGLVERTEXATTRIB4NUSVPROC) (GLuint index, const GLushort *v);
typedef void (APIENTRYP PFNGLVERTEXATTRIB4BVPROC) (GLuint index, const GLbyte *v);
typedef void (APIENTRYP PFNGLVERTEXATTRIB4DPROC) (GLuint index, GLdouble x, GLdouble y, GLdouble z, GLdouble w);
typedef void (APIENTRYP PFNGLVERTEXATTRIB4DVPROC) (GLuint index, const GLdouble *v);
typedef void (APIENTRYP PFNGLVERTEXATTRIB4FPROC) (GLuint index, GLfloat x, GLfloat y, GLfloat z, GLfloat w);
typedef void (APIENTRYP PFNGLVERTEXATTRIB4FVPROC) (GLuint index, const GLfloat *v);
typedef void (APIENTRYP PFNGLVERTEXATTRIB4IVPROC) (GLuint index, const GLint *v);
typedef void (APIENTRYP PFNGLVERTEXATTRIB4SPROC) (GLuint index, GLshort x, GLshort y, GLshort z, GLshort w);
typedef void (APIENTRYP PFNGLVERTEXATTRIB4SVPROC) (GLuint index, const GLshort *v);
typedef void (APIENTRYP PFNGLVERTEXATTRIB4UBVPROC) (GLuint index, const GLubyte *v);
typedef void (APIENTRYP PFNGLVERTEXATTRIB4UIVPROC) (GLuint index, const GLuint *v);
typedef void (APIENTRYP PFNGLVERTEXATTRIB4USVPROC) (GLuint index, const GLushort *v);
typedef void (APIENTRYP PFNGLVERTEXATTRIBPOINTERPROC) (GLuint index, GLint size, GLenum type, GLboolean normalized, GLsizei stride, const void *pointer);

#define GL_PIXEL_PACK_BUFFER              0x88EB
#define GL_PIXEL_UNPACK_BUFFER            0x88EC
#define GL_PIXEL_PACK_BUFFER_BINDING      0x88ED
#define GL_PIXEL_UNPACK_BUFFER_BINDING    0x88EF
#define GL_FLOAT_MAT2x3                   0x8B65
#define GL_FLOAT_MAT2x4                   0x8B66
#define GL_FLOAT_MAT3x2                   0x8B67
#define GL_FLOAT_MAT3x4                   0x8B68
#define GL_FLOAT_MAT4x2                   0x8B69
#define GL_FLOAT_MAT4x3                   0x8B6A
#define GL_SRGB                           0x8C40
#define GL_SRGB8                          0x8C41
#define GL_SRGB_ALPHA                     0x8C42
#define GL_SRGB8_ALPHA8                   0x8C43
#define GL_COMPRESSED_SRGB                0x8C48
#define GL_COMPRESSED_SRGB_ALPHA          0x8C49
typedef void (APIENTRYP PFNGLUNIFORMMATRIX2X3FVPROC) (GLint location, GLsizei count, GLboolean transpose, const GLfloat *value);
typedef void (APIENTRYP PFNGLUNIFORMMATRIX3X2FVPROC) (GLint location, GLsizei count, GLboolean transpose, const GLfloat *value);
typedef void (APIENTRYP PFNGLUNIFORMMATRIX2X4FVPROC) (GLint location, GLsizei count, GLboolean transpose, const GLfloat *value);
typedef void (APIENTRYP PFNGLUNIFORMMATRIX4X2FVPROC) (GLint location, GLsizei count, GLboolean transpose, const GLfloat *value);
typedef void (APIENTRYP PFNGLUNIFORMMATRIX3X4FVPROC) (GLint location, GLsizei count, GLboolean transpose, const GLfloat *value);
typedef void (APIENTRYP PFNGLUNIFORMMATRIX4X3FVPROC) (GLint location, GLsizei count, GLboolean transpose, const GLfloat *value);

typedef unsigned short GLhalf;
#define GL_COMPARE_REF_TO_TEXTURE         0x884E
#define GL_CLIP_DISTANCE0                 0x3000
#define GL_CLIP_DISTANCE1                 0x3001
#define GL_CLIP_DISTANCE2                 0x3002
#define GL_CLIP_DISTANCE3                 0x3003
#define GL_CLIP_DISTANCE4                 0x3004
#define GL_CLIP_DISTANCE5                 0x3005
#define GL_CLIP_DISTANCE6                 0x3006
#define GL_CLIP_DISTANCE7                 0x3007
#define GL_MAX_CLIP_DISTANCES             0x0D32
#define GL_MAJOR_VERSION                  0x821B
#define GL_MINOR_VERSION                  0x821C
#define GL_NUM_EXTENSIONS                 0x821D
#define GL_CONTEXT_FLAGS                  0x821E
#define GL_COMPRESSED_RED                 0x8225
#define GL_COMPRESSED_RG                  0x8226
#define GL_CONTEXT_FLAG_FORWARD_COMPATIBLE_BIT 0x00000001
#define GL_RGBA32F                        0x8814
#define GL_RGB32F                         0x8815
#define GL_RGBA16F                        0x881A
#define GL_RGB16F                         0x881B
#define GL_VERTEX_ATTRIB_ARRAY_INTEGER    0x88FD
#define GL_MAX_ARRAY_TEXTURE_LAYERS       0x88FF
#define GL_MIN_PROGRAM_TEXEL_OFFSET       0x8904
#define GL_MAX_PROGRAM_TEXEL_OFFSET       0x8905
#define GL_CLAMP_READ_COLOR               0x891C
#define GL_FIXED_ONLY                     0x891D
#define GL_MAX_VARYING_COMPONENTS         0x8B4B
#define GL_TEXTURE_1D_ARRAY               0x8C18
#define GL_PROXY_TEXTURE_1D_ARRAY         0x8C19
#define GL_TEXTURE_2D_ARRAY               0x8C1A
#define GL_PROXY_TEXTURE_2D_ARRAY         0x8C1B
#define GL_TEXTURE_BINDING_1D_ARRAY       0x8C1C
#define GL_TEXTURE_BINDING_2D_ARRAY       0x8C1D
#define GL_R11F_G11F_B10F                 0x8C3A
#define GL_UNSIGNED_INT_10F_11F_11F_REV   0x8C3B
#define GL_RGB9_E5                        0x8C3D
#define GL_UNSIGNED_INT_5_9_9_9_REV       0x8C3E
#define GL_TEXTURE_SHARED_SIZE            0x8C3F
#define GL_TRANSFORM_FEEDBACK_VARYING_MAX_LENGTH 0x8C76
#define GL_TRANSFORM_FEEDBACK_BUFFER_MODE 0x8C7F
#define GL_MAX_TRANSFORM_FEEDBACK_SEPARATE_COMPONENTS 0x8C80
#define GL_TRANSFORM_FEEDBACK_VARYINGS    0x8C83
#define GL_TRANSFORM_FEEDBACK_BUFFER_START 0x8C84
#define GL_TRANSFORM_FEEDBACK_BUFFER_SIZE 0x8C85
#define GL_PRIMITIVES_GENERATED           0x8C87
#define GL_TRANSFORM_FEEDBACK_PRIMITIVES_WRITTEN 0x8C88
#define GL_RASTERIZER_DISCARD             0x8C89
#define GL_MAX_TRANSFORM_FEEDBACK_INTERLEAVED_COMPONENTS 0x8C8A
#define GL_MAX_TRANSFORM_FEEDBACK_SEPARATE_ATTRIBS 0x8C8B
#define GL_INTERLEAVED_ATTRIBS            0x8C8C
#define GL_SEPARATE_ATTRIBS               0x8C8D
#define GL_TRANSFORM_FEEDBACK_BUFFER      0x8C8E
#define GL_TRANSFORM_FEEDBACK_BUFFER_BINDING 0x8C8F
#define GL_RGBA32UI                       0x8D70
#define GL_RGB32UI                        0x8D71
#define GL_RGBA16UI                       0x8D76
#define GL_RGB16UI                        0x8D77
#define GL_RGBA8UI                        0x8D7C
#define GL_RGB8UI                         0x8D7D
#define GL_RGBA32I                        0x8D82
#define GL_RGB32I                         0x8D83
#define GL_RGBA16I                        0x8D88
#define GL_RGB16I                         0x8D89
#define GL_RGBA8I                         0x8D8E
#define GL_RGB8I                          0x8D8F
#define GL_RED_INTEGER                    0x8D94
#define GL_GREEN_INTEGER                  0x8D95
#define GL_BLUE_INTEGER                   0x8D96
#define GL_RGB_INTEGER                    0x8D98
#define GL_RGBA_INTEGER                   0x8D99
#define GL_BGR_INTEGER                    0x8D9A
#define GL_BGRA_INTEGER                   0x8D9B
#define GL_SAMPLER_1D_ARRAY               0x8DC0
#define GL_SAMPLER_2D_ARRAY               0x8DC1
#define GL_SAMPLER_1D_ARRAY_SHADOW        0x8DC3
#define GL_SAMPLER_2D_ARRAY_SHADOW        0x8DC4
#define GL_SAMPLER_CUBE_SHADOW            0x8DC5
#define GL_UNSIGNED_INT_VEC2              0x8DC6
#define GL_UNSIGNED_INT_VEC3              0x8DC7
#define GL_UNSIGNED_INT_VEC4              0x8DC8
#define GL_INT_SAMPLER_1D                 0x8DC9
#define GL_INT_SAMPLER_2D                 0x8DCA
#define GL_INT_SAMPLER_3D                 0x8DCB
#define GL_INT_SAMPLER_CUBE               0x8DCC
#define GL_INT_SAMPLER_1D_ARRAY           0x8DCE
#define GL_INT_SAMPLER_2D_ARRAY           0x8DCF
#define GL_UNSIGNED_INT_SAMPLER_1D        0x8DD1
#define GL_UNSIGNED_INT_SAMPLER_2D        0x8DD2
#define GL_UNSIGNED_INT_SAMPLER_3D        0x8DD3
#define GL_UNSIGNED_INT_SAMPLER_CUBE      0x8DD4
#define GL_UNSIGNED_INT_SAMPLER_1D_ARRAY  0x8DD6
#define GL_UNSIGNED_INT_SAMPLER_2D_ARRAY  0x8DD7
#define GL_QUERY_WAIT                     0x8E13
#define GL_QUERY_NO_WAIT                  0x8E14
#define GL_QUERY_BY_REGION_WAIT           0x8E15
#define GL_QUERY_BY_REGION_NO_WAIT        0x8E16
#define GL_BUFFER_ACCESS_FLAGS            0x911F
#define GL_BUFFER_MAP_LENGTH              0x9120
#define GL_BUFFER_MAP_OFFSET              0x9121
#define GL_DEPTH_COMPONENT32F             0x8CAC
#define GL_DEPTH32F_STENCIL8              0x8CAD
#define GL_FLOAT_32_UNSIGNED_INT_24_8_REV 0x8DAD
#define GL_INVALID_FRAMEBUFFER_OPERATION  0x0506
#define GL_FRAMEBUFFER_ATTACHMENT_COLOR_ENCODING 0x8210
#define GL_FRAMEBUFFER_ATTACHMENT_COMPONENT_TYPE 0x8211
#define GL_FRAMEBUFFER_ATTACHMENT_RED_SIZE 0x8212
#define GL_FRAMEBUFFER_ATTACHMENT_GREEN_SIZE 0x8213
#define GL_FRAMEBUFFER_ATTACHMENT_BLUE_SIZE 0x8214
#define GL_FRAMEBUFFER_ATTACHMENT_ALPHA_SIZE 0x8215
#define GL_FRAMEBUFFER_ATTACHMENT_DEPTH_SIZE 0x8216
#define GL_FRAMEBUFFER_ATTACHMENT_STENCIL_SIZE 0x8217
#define GL_FRAMEBUFFER_DEFAULT            0x8218
#define GL_FRAMEBUFFER_UNDEFINED          0x8219
#define GL_DEPTH_STENCIL_ATTACHMENT       0x821A
#define GL_MAX_RENDERBUFFER_SIZE          0x84E8
#define GL_DEPTH_STENCIL                  0x84F9
#define GL_UNSIGNED_INT_24_8              0x84FA
#define GL_DEPTH24_STENCIL8               0x88F0
#define GL_TEXTURE_STENCIL_SIZE           0x88F1
#define GL_TEXTURE_RED_TYPE               0x8C10
#define GL_TEXTURE_GREEN_TYPE             0x8C11
#define GL_TEXTURE_BLUE_TYPE              0x8C12
#define GL_TEXTURE_ALPHA_TYPE             0x8C13
#define GL_TEXTURE_DEPTH_TYPE             0x8C16
#define GL_UNSIGNED_NORMALIZED            0x8C17
#define GL_FRAMEBUFFER_BINDING            0x8CA6
#define GL_DRAW_FRAMEBUFFER_BINDING       0x8CA6
#define GL_RENDERBUFFER_BINDING           0x8CA7
#define GL_READ_FRAMEBUFFER               0x8CA8
#define GL_DRAW_FRAMEBUFFER               0x8CA9
#define GL_READ_FRAMEBUFFER_BINDING       0x8CAA
#define GL_RENDERBUFFER_SAMPLES           0x8CAB
#define GL_FRAMEBUFFER_ATTACHMENT_OBJECT_TYPE 0x8CD0
#define GL_FRAMEBUFFER_ATTACHMENT_OBJECT_NAME 0x8CD1
#define GL_FRAMEBUFFER_ATTACHMENT_TEXTURE_LEVEL 0x8CD2
#define GL_FRAMEBUFFER_ATTACHMENT_TEXTURE_CUBE_MAP_FACE 0x8CD3
#define GL_FRAMEBUFFER_ATTACHMENT_TEXTURE_LAYER 0x8CD4
#define GL_FRAMEBUFFER_COMPLETE           0x8CD5
#define GL_FRAMEBUFFER_INCOMPLETE_ATTACHMENT 0x8CD6
#define GL_FRAMEBUFFER_INCOMPLETE_MISSING_ATTACHMENT 0x8CD7
#define GL_FRAMEBUFFER_INCOMPLETE_DRAW_BUFFER 0x8CDB
#define GL_FRAMEBUFFER_INCOMPLETE_READ_BUFFER 0x8CDC
#define GL_FRAMEBUFFER_UNSUPPORTED        0x8CDD
#define GL_MAX_COLOR_ATTACHMENTS          0x8CDF
#define GL_COLOR_ATTACHMENT0              0x8CE0
#define GL_COLOR_ATTACHMENT1              0x8CE1
#define GL_COLOR_ATTACHMENT2              0x8CE2
#define GL_COLOR_ATTACHMENT3              0x8CE3
#define GL_COLOR_ATTACHMENT4              0x8CE4
#define GL_COLOR_ATTACHMENT5              0x8CE5
#define GL_COLOR_ATTACHMENT6              0x8CE6
#define GL_COLOR_ATTACHMENT7              0x8CE7
#define GL_COLOR_ATTACHMENT8              0x8CE8
#define GL_COLOR_ATTACHMENT9              0x8CE9
#define GL_COLOR_ATTACHMENT10             0x8CEA
#define GL_COLOR_ATTACHMENT11             0x8CEB
#define GL_COLOR_ATTACHMENT12             0x8CEC
#define GL_COLOR_ATTACHMENT13             0x8CED
#define GL_COLOR_ATTACHMENT14             0x8CEE
#define GL_COLOR_ATTACHMENT15             0x8CEF
#define GL_DEPTH_ATTACHMENT               0x8D00
#define GL_STENCIL_ATTACHMENT             0x8D20
#define GL_FRAMEBUFFER                    0x8D40
#define GL_RENDERBUFFER                   0x8D41
#define GL_RENDERBUFFER_WIDTH             0x8D42
#define GL_RENDERBUFFER_HEIGHT            0x8D43
#define GL_RENDERBUFFER_INTERNAL_FORMAT   0x8D44
#define GL_STENCIL_INDEX1                 0x8D46
#define GL_STENCIL_INDEX4                 0x8D47
#define GL_STENCIL_INDEX8                 0x8D48
#define GL_STENCIL_INDEX16                0x8D49
#define GL_RENDERBUFFER_RED_SIZE          0x8D50
#define GL_RENDERBUFFER_GREEN_SIZE        0x8D51
#define GL_RENDERBUFFER_BLUE_SIZE         0x8D52
#define GL_RENDERBUFFER_ALPHA_SIZE        0x8D53
#define GL_RENDERBUFFER_DEPTH_SIZE        0x8D54
#define GL_RENDERBUFFER_STENCIL_SIZE      0x8D55
#define GL_FRAMEBUFFER_INCOMPLETE_MULTISAMPLE 0x8D56
#define GL_MAX_SAMPLES                    0x8D57
#define GL_FRAMEBUFFER_SRGB               0x8DB9
#define GL_HALF_FLOAT                     0x140B
#define GL_MAP_READ_BIT                   0x0001
#define GL_MAP_WRITE_BIT                  0x0002
#define GL_MAP_INVALIDATE_RANGE_BIT       0x0004
#define GL_MAP_INVALIDATE_BUFFER_BIT      0x0008
#define GL_MAP_FLUSH_EXPLICIT_BIT         0x0010
#define GL_MAP_UNSYNCHRONIZED_BIT         0x0020
#define GL_COMPRESSED_RED_RGTC1           0x8DBB
#define GL_COMPRESSED_SIGNED_RED_RGTC1    0x8DBC
#define GL_COMPRESSED_RG_RGTC2            0x8DBD
#define GL_COMPRESSED_SIGNED_RG_RGTC2     0x8DBE
#define GL_RG                             0x8227
#define GL_RG_INTEGER                     0x8228
#define GL_R8                             0x8229
#define GL_R16                            0x822A
#define GL_RG8                            0x822B
#define GL_RG16                           0x822C
#define GL_R16F                           0x822D
#define GL_R32F                           0x822E
#define GL_RG16F                          0x822F
#define GL_RG32F                          0x8230
#define GL_R8I                            0x8231
#define GL_R8UI                           0x8232
#define GL_R16I                           0x8233
#define GL_R16UI                          0x8234
#define GL_R32I                           0x8235
#define GL_R32UI                          0x8236
#define GL_RG8I                           0x8237
#define GL_RG8UI                          0x8238
#define GL_RG16I                          0x8239
#define GL_RG16UI                         0x823A
#define GL_RG32I                          0x823B
#define GL_RG32UI                         0x823C
#define GL_VERTEX_ARRAY_BINDING           0x85B5
typedef void (APIENTRYP PFNGLCOLORMASKIPROC) (GLuint index, GLboolean r, GLboolean g, GLboolean b, GLboolean a);
typedef void (APIENTRYP PFNGLGETBOOLEANI_VPROC) (GLenum target, GLuint index, GLboolean *data);
typedef void (APIENTRYP PFNGLGETINTEGERI_VPROC) (GLenum target, GLuint index, GLint *data);
typedef void (APIENTRYP PFNGLENABLEIPROC) (GLenum target, GLuint index);
typedef void (APIENTRYP PFNGLDISABLEIPROC) (GLenum target, GLuint index);
typedef GLboolean (APIENTRYP PFNGLISENABLEDIPROC) (GLenum target, GLuint index);
typedef void (APIENTRYP PFNGLBEGINTRANSFORMFEEDBACKPROC) (GLenum primitiveMode);
typedef void (APIENTRYP PFNGLENDTRANSFORMFEEDBACKPROC) (void);
typedef void (APIENTRYP PFNGLBINDBUFFERRANGEPROC) (GLenum target, GLuint index, GLuint buffer, GLintptr offset, GLsizeiptr size);
typedef void (APIENTRYP PFNGLBINDBUFFERBASEPROC) (GLenum target, GLuint index, GLuint buffer);
typedef void (APIENTRYP PFNGLTRANSFORMFEEDBACKVARYINGSPROC) (GLuint program, GLsizei count, const GLchar *const*varyings, GLenum bufferMode);
typedef void (APIENTRYP PFNGLGETTRANSFORMFEEDBACKVARYINGPROC) (GLuint program, GLuint index, GLsizei bufSize, GLsizei *length, GLsizei *size, GLenum *type, GLchar *name);
typedef void (APIENTRYP PFNGLCLAMPCOLORPROC) (GLenum target, GLenum clamp);
typedef void (APIENTRYP PFNGLBEGINCONDITIONALRENDERPROC) (GLuint id, GLenum mode);
typedef void (APIENTRYP PFNGLENDCONDITIONALRENDERPROC) (void);
typedef void (APIENTRYP PFNGLVERTEXATTRIBIPOINTERPROC) (GLuint index, GLint size, GLenum type, GLsizei stride, const void *pointer);
typedef void (APIENTRYP PFNGLGETVERTEXATTRIBIIVPROC) (GLuint index, GLenum pname, GLint *params);
typedef void (APIENTRYP PFNGLGETVERTEXATTRIBIUIVPROC) (GLuint index, GLenum pname, GLuint *params);
typedef void (APIENTRYP PFNGLVERTEXATTRIBI1IPROC) (GLuint index, GLint x);
typedef void (APIENTRYP PFNGLVERTEXATTRIBI2IPROC) (GLuint index, GLint x, GLint y);
typedef void (APIENTRYP PFNGLVERTEXATTRIBI3IPROC) (GLuint index, GLint x, GLint y, GLint z);
typedef void (APIENTRYP PFNGLVERTEXATTRIBI4IPROC) (GLuint index, GLint x, GLint y, GLint z, GLint w);
typedef void (APIENTRYP PFNGLVERTEXATTRIBI1UIPROC) (GLuint index, GLuint x);
typedef void (APIENTRYP PFNGLVERTEXATTRIBI2UIPROC) (GLuint index, GLuint x, GLuint y);
typedef void (APIENTRYP PFNGLVERTEXATTRIBI3UIPROC) (GLuint index, GLuint x, GLuint y, GLuint z);
typedef void (APIENTRYP PFNGLVERTEXATTRIBI4UIPROC) (GLuint index, GLuint x, GLuint y, GLuint z, GLuint w);
typedef void (APIENTRYP PFNGLVERTEXATTRIBI1IVPROC) (GLuint index, const GLint *v);
typedef void (APIENTRYP PFNGLVERTEXATTRIBI2IVPROC) (GLuint index, const GLint *v);
typedef void (APIENTRYP PFNGLVERTEXATTRIBI3IVPROC) (GLuint index, const GLint *v);
typedef void (APIENTRYP PFNGLVERTEXATTRIBI4IVPROC) (GLuint index, const GLint *v);
typedef void (APIENTRYP PFNGLVERTEXATTRIBI1UIVPROC) (GLuint index, const GLuint *v);
typedef void (APIENTRYP PFNGLVERTEXATTRIBI2UIVPROC) (GLuint index, const GLuint *v);
typedef void (APIENTRYP PFNGLVERTEXATTRIBI3UIVPROC) (GLuint index, const GLuint *v);
typedef void (APIENTRYP PFNGLVERTEXATTRIBI4UIVPROC) (GLuint index, const GLuint *v);
typedef void (APIENTRYP PFNGLVERTEXATTRIBI4BVPROC) (GLuint index, const GLbyte *v);
typedef void (APIENTRYP PFNGLVERTEXATTRIBI4SVPROC) (GLuint index, const GLshort *v);
typedef void (APIENTRYP PFNGLVERTEXATTRIBI4UBVPROC) (GLuint index, const GLubyte *v);
typedef void (APIENTRYP PFNGLVERTEXATTRIBI4USVPROC) (GLuint index, const GLushort *v);
typedef void (APIENTRYP PFNGLGETUNIFORMUIVPROC) (GLuint program, GLint location, GLuint *params);
typedef void (APIENTRYP PFNGLBINDFRAGDATALOCATIONPROC) (GLuint program, GLuint color, const GLchar *name);
typedef GLint (APIENTRYP PFNGLGETFRAGDATALOCATIONPROC) (GLuint program, const GLchar *name);
typedef void (APIENTRYP PFNGLUNIFORM1UIPROC) (GLint location, GLuint v0);
typedef void (APIENTRYP PFNGLUNIFORM2UIPROC) (GLint location, GLuint v0, GLuint v1);
typedef void (APIENTRYP PFNGLUNIFORM3UIPROC) (GLint location, GLuint v0, GLuint v1, GLuint v2);
typedef void (APIENTRYP PFNGLUNIFORM4UIPROC) (GLint location, GLuint v0, GLuint v1, GLuint v2, GLuint v3);
typedef void (APIENTRYP PFNGLUNIFORM1UIVPROC) (GLint location, GLsizei count, const GLuint *value);
typedef void (APIENTRYP PFNGLUNIFORM2UIVPROC) (GLint location, GLsizei count, const GLuint *value);
typedef void (APIENTRYP PFNGLUNIFORM3UIVPROC) (GLint location, GLsizei count, const GLuint *value);
typedef void (APIENTRYP PFNGLUNIFORM4UIVPROC) (GLint location, GLsizei count, const GLuint *value);
typedef void (APIENTRYP PFNGLTEXPARAMETERIIVPROC) (GLenum target, GLenum pname, const GLint *params);
typedef void (APIENTRYP PFNGLTEXPARAMETERIUIVPROC) (GLenum target, GLenum pname, const GLuint *params);
typedef void (APIENTRYP PFNGLGETTEXPARAMETERIIVPROC) (GLenum target, GLenum pname, GLint *params);
typedef void (APIENTRYP PFNGLGETTEXPARAMETERIUIVPROC) (GLenum target, GLenum pname, GLuint *params);
typedef void (APIENTRYP PFNGLCLEARBUFFERIVPROC) (GLenum buffer, GLint drawbuffer, const GLint *value);
typedef void (APIENTRYP PFNGLCLEARBUFFERUIVPROC) (GLenum buffer, GLint drawbuffer, const GLuint *value);
typedef void (APIENTRYP PFNGLCLEARBUFFERFVPROC) (GLenum buffer, GLint drawbuffer, const GLfloat *value);
typedef void (APIENTRYP PFNGLCLEARBUFFERFIPROC) (GLenum buffer, GLint drawbuffer, GLfloat depth, GLint stencil);
typedef const GLubyte *(APIENTRYP PFNGLGETSTRINGIPROC) (GLenum name, GLuint index);
typedef GLboolean (APIENTRYP PFNGLISRENDERBUFFERPROC) (GLuint renderbuffer);
typedef void (APIENTRYP PFNGLBINDRENDERBUFFERPROC) (GLenum target, GLuint renderbuffer);
typedef void (APIENTRYP PFNGLDELETERENDERBUFFERSPROC) (GLsizei n, const GLuint *renderbuffers);
typedef void (APIENTRYP PFNGLGENRENDERBUFFERSPROC) (GLsizei n, GLuint *renderbuffers);
typedef void (APIENTRYP PFNGLRENDERBUFFERSTORAGEPROC) (GLenum target, GLenum internalformat, GLsizei width, GLsizei height);
typedef void (APIENTRYP PFNGLGETRENDERBUFFERPARAMETERIVPROC) (GLenum target, GLenum pname, GLint *params);
typedef GLboolean (APIENTRYP PFNGLISFRAMEBUFFERPROC) (GLuint framebuffer);
typedef void (APIENTRYP PFNGLBINDFRAMEBUFFERPROC) (GLenum target, GLuint framebuffer);
typedef void (APIENTRYP PFNGLDELETEFRAMEBUFFERSPROC) (GLsizei n, const GLuint *framebuffers);
typedef void (APIENTRYP PFNGLGENFRAMEBUFFERSPROC) (GLsizei n, GLuint *framebuffers);
typedef GLenum (APIENTRYP PFNGLCHECKFRAMEBUFFERSTATUSPROC) (GLenum target);
typedef void (APIENTRYP PFNGLFRAMEBUFFERTEXTURE1DPROC) (GLenum target, GLenum attachment, GLenum textarget, GLuint texture, GLint level);
typedef void (APIENTRYP PFNGLFRAMEBUFFERTEXTURE2DPROC) (GLenum target, GLenum attachment, GLenum textarget, GLuint texture, GLint level);
typedef void (APIENTRYP PFNGLFRAMEBUFFERTEXTURE3DPROC) (GLenum target, GLenum attachment, GLenum textarget, GLuint texture, GLint level, GLint zoffset);
typedef void (APIENTRYP PFNGLFRAMEBUFFERRENDERBUFFERPROC) (GLenum target, GLenum attachment, GLenum renderbuffertarget, GLuint renderbuffer);
typedef void (APIENTRYP PFNGLGETFRAMEBUFFERATTACHMENTPARAMETERIVPROC) (GLenum target, GLenum attachment, GLenum pname, GLint *params);
typedef void (APIENTRYP PFNGLGENERATEMIPMAPPROC) (GLenum target);
typedef void (APIENTRYP PFNGLBLITFRAMEBUFFERPROC) (GLint srcX0, GLint srcY0, GLint srcX1, GLint srcY1, GLint dstX0, GLint dstY0, GLint dstX1, GLint dstY1, GLbitfield mask, GLenum filter);
typedef void (APIENTRYP PFNGLRENDERBUFFERSTORAGEMULTISAMPLEPROC) (GLenum target, GLsizei samples, GLenum internalformat, GLsizei width, GLsizei height);
typedef void (APIENTRYP PFNGLFRAMEBUFFERTEXTURELAYERPROC) (GLenum target, GLenum attachment, GLuint texture, GLint level, GLint layer);
typedef void *(APIENTRYP PFNGLMAPBUFFERRANGEPROC) (GLenum target, GLintptr offset, GLsizeiptr length, GLbitfield access);
typedef void (APIENTRYP PFNGLFLUSHMAPPEDBUFFERRANGEPROC) (GLenum target, GLintptr offset, GLsizeiptr length);
typedef void (APIENTRYP PFNGLBINDVERTEXARRAYPROC) (GLuint array);
typedef void (APIENTRYP PFNGLDELETEVERTEXARRAYSPROC) (GLsizei n, const GLuint *arrays);
typedef void (APIENTRYP PFNGLGENVERTEXARRAYSPROC) (GLsizei n, GLuint *arrays);
typedef GLboolean (APIENTRYP PFNGLISVERTEXARRAYPROC) (GLuint array);

#define GL_SAMPLER_2D_RECT                0x8B63
#define GL_SAMPLER_2D_RECT_SHADOW         0x8B64
#define GL_SAMPLER_BUFFER                 0x8DC2
#define GL_INT_SAMPLER_2D_RECT            0x8DCD
#define GL_INT_SAMPLER_BUFFER             0x8DD0
#define GL_UNSIGNED_INT_SAMPLER_2D_RECT   0x8DD5
#define GL_UNSIGNED_INT_SAMPLER_BUFFER    0x8DD8
#define GL_TEXTURE_BUFFER                 0x8C2A
#define GL_MAX_TEXTURE_BUFFER_SIZE        0x8C2B
#define GL_TEXTURE_BINDING_BUFFER         0x8C2C
#define GL_TEXTURE_BUFFER_DATA_STORE_BINDING 0x8C2D
#define GL_TEXTURE_RECTANGLE              0x84F5
#define GL_TEXTURE_BINDING_RECTANGLE      0x84F6
#define GL_PROXY_TEXTURE_RECTANGLE        0x84F7
#define GL_MAX_RECTANGLE_TEXTURE_SIZE     0x84F8
#define GL_R8_SNORM                       0x8F94
#define GL_RG8_SNORM                      0x8F95
#define GL_RGB8_SNORM                     0x8F96
#define GL_RGBA8_SNORM                    0x8F97
#define GL_R16_SNORM                      0x8F98
#define GL_RG16_SNORM                     0x8F99
#define GL_RGB16_SNORM                    0x8F9A
#define GL_RGBA16_SNORM                   0x8F9B
#define GL_SIGNED_NORMALIZED              0x8F9C
#define GL_PRIMITIVE_RESTART              0x8F9D
#define GL_PRIMITIVE_RESTART_INDEX        0x8F9E
#define GL_COPY_READ_BUFFER               0x8F36
#define GL_COPY_WRITE_BUFFER              0x8F37
#define GL_UNIFORM_BUFFER                 0x8A11
#define GL_UNIFORM_BUFFER_BINDING         0x8A28
#define GL_UNIFORM_BUFFER_START           0x8A29
#define GL_UNIFORM_BUFFER_SIZE            0x8A2A
#define GL_MAX_VERTEX_UNIFORM_BLOCKS      0x8A2B
#define GL_MAX_FRAGMENT_UNIFORM_BLOCKS    0x8A2D
#define GL_MAX_COMBINED_UNIFORM_BLOCKS    0x8A2E
#define GL_MAX_UNIFORM_BUFFER_BINDINGS    0x8A2F
#define GL_MAX_UNIFORM_BLOCK_SIZE         0x8A30
#define GL_MAX_COMBINED_VERTEX_UNIFORM_COMPONENTS 0x8A31
#define GL_MAX_COMBINED_FRAGMENT_UNIFORM_COMPONENTS 0x8A33
#define GL_UNIFORM_BUFFER_OFFSET_ALIGNMENT 0x8A34
#define GL_ACTIVE_UNIFORM_BLOCK_MAX_NAME_LENGTH 0x8A35
#define GL_ACTIVE_UNIFORM_BLOCKS          0x8A36
#define GL_UNIFORM_TYPE                   0x8A37
#define GL_UNIFORM_SIZE                   0x8A38
#define GL_UNIFORM_NAME_LENGTH            0x8A39
#define GL_UNIFORM_BLOCK_INDEX            0x8A3A
#define GL_UNIFORM_OFFSET                 0x8A3B
#define GL_UNIFORM_ARRAY_STRIDE           0x8A3C
#define GL_UNIFORM_MATRIX_STRIDE          0x8A3D
#define GL_UNIFORM_IS_ROW_MAJOR           0x8A3E
#define GL_UNIFORM_BLOCK_BINDING          0x8A3F
#define GL_UNIFORM_BLOCK_DATA_SIZE        0x8A40
#define GL_UNIFORM_BLOCK_NAME_LENGTH      0x8A41
#define GL_UNIFORM_BLOCK_ACTIVE_UNIFORMS  0x8A42
#define GL_UNIFORM_BLOCK_ACTIVE_UNIFORM_INDICES 0x8A43
#define GL_UNIFORM_BLOCK_REFERENCED_BY_VERTEX_SHADER 0x8A44
#define GL_UNIFORM_BLOCK_REFERENCED_BY_FRAGMENT_SHADER 0x8A46
#define GL_INVALID_INDEX                  0xFFFFFFFFu
typedef void (APIENTRYP PFNGLDRAWARRAYSINSTANCEDPROC) (GLenum mode, GLint first, GLsizei count, GLsizei instancecount);
typedef void (APIENTRYP PFNGLDRAWELEMENTSINSTANCEDPROC) (GLenum mode, GLsizei count, GLenum type, const void *indices, GLsizei instancecount);
typedef void (APIENTRYP PFNGLTEXBUFFERPROC) (GLenum target, GLenum internalformat, GLuint buffer);
typedef void (APIENTRYP PFNGLPRIMITIVERESTARTINDEXPROC) (GLuint index);
typedef void (APIENTRYP PFNGLCOPYBUFFERSUBDATAPROC) (GLenum readTarget, GLenum writeTarget, GLintptr readOffset, GLintptr writeOffset, GLsizeiptr size);
typedef void (APIENTRYP PFNGLGETUNIFORMINDICESPROC) (GLuint program, GLsizei uniformCount, const GLchar *const*uniformNames, GLuint *uniformIndices);
typedef void (APIENTRYP PFNGLGETACTIVEUNIFORMSIVPROC) (GLuint program, GLsizei uniformCount, const GLuint *uniformIndices, GLenum pname, GLint *params);
typedef void (APIENTRYP PFNGLGETACTIVEUNIFORMNAMEPROC) (GLuint program, GLuint uniformIndex, GLsizei bufSize, GLsizei *length, GLchar *uniformName);
typedef GLuint (APIENTRYP PFNGLGETUNIFORMBLOCKINDEXPROC) (GLuint program, const GLchar *uniformBlockName);
typedef void (APIENTRYP PFNGLGETACTIVEUNIFORMBLOCKIVPROC) (GLuint program, GLuint uniformBlockIndex, GLenum pname, GLint *params);
typedef void (APIENTRYP PFNGLGETACTIVEUNIFORMBLOCKNAMEPROC) (GLuint program, GLuint uniformBlockIndex, GLsizei bufSize, GLsizei *length, GLchar *uniformBlockName);
typedef void (APIENTRYP PFNGLUNIFORMBLOCKBINDINGPROC) (GLuint program, GLuint uniformBlockIndex, GLuint uniformBlockBinding);

typedef struct __GLsync *GLsync;
typedef uint64_t GLuint64;
typedef int64_t GLint64;
#define GL_CONTEXT_CORE_PROFILE_BIT       0x00000001
#define GL_CONTEXT_COMPATIBILITY_PROFILE_BIT 0x00000002
#define GL_LINES_ADJACENCY                0x000A
#define GL_LINE_STRIP_ADJACENCY           0x000B
#define GL_TRIANGLES_ADJACENCY            0x000C
#define GL_TRIANGLE_STRIP_ADJACENCY       0x000D
#define GL_PROGRAM_POINT_SIZE             0x8642
#define GL_MAX_GEOMETRY_TEXTURE_IMAGE_UNITS 0x8C29
#define GL_FRAMEBUFFER_ATTACHMENT_LAYERED 0x8DA7
#define GL_FRAMEBUFFER_INCOMPLETE_LAYER_TARGETS 0x8DA8
#define GL_GEOMETRY_SHADER                0x8DD9
#define GL_GEOMETRY_VERTICES_OUT          0x8916
#define GL_GEOMETRY_INPUT_TYPE            0x8917
#define GL_GEOMETRY_OUTPUT_TYPE           0x8918
#define GL_MAX_GEOMETRY_UNIFORM_COMPONENTS 0x8DDF
#define GL_MAX_GEOMETRY_OUTPUT_VERTICES   0x8DE0
#define GL_MAX_GEOMETRY_TOTAL_OUTPUT_COMPONENTS 0x8DE1
#define GL_MAX_VERTEX_OUTPUT_COMPONENTS   0x9122
#define GL_MAX_GEOMETRY_INPUT_COMPONENTS  0x9123
#define GL_MAX_GEOMETRY_OUTPUT_COMPONENTS 0x9124
#define GL_MAX_FRAGMENT_INPUT_COMPONENTS  0x9125
#define GL_CONTEXT_PROFILE_MASK           0x9126
#define GL_DEPTH_CLAMP                    0x864F
#define GL_QUADS_FOLLOW_PROVOKING_VERTEX_CONVENTION 0x8E4C
#define GL_FIRST_VERTEX_CONVENTION        0x8E4D
#define GL_LAST_VERTEX_CONVENTION         0x8E4E
#define GL_PROVOKING_VERTEX               0x8E4F
#define GL_TEXTURE_CUBE_MAP_SEAMLESS      0x884F
#define GL_MAX_SERVER_WAIT_TIMEOUT        0x9111
#define GL_OBJECT_TYPE                    0x9112
#define GL_SYNC_CONDITION                 0x9113
#define GL_SYNC_STATUS                    0x9114
#define GL_SYNC_FLAGS                     0x9115
#define GL_SYNC_FENCE                     0x9116
#define GL_SYNC_GPU_COMMANDS_COMPLETE     0x9117
#define GL_UNSIGNALED                     0x9118
#define GL_SIGNALED                       0x9119
#define GL_ALREADY_SIGNALED               0x911A
#define GL_TIMEOUT_EXPIRED                0x911B
#define GL_CONDITION_SATISFIED            0x911C
#define GL_WAIT_FAILED                    0x911D
#define GL_TIMEOUT_IGNORED                0xFFFFFFFFFFFFFFFFull
#define GL_SYNC_FLUSH_COMMANDS_BIT        0x00000001
#define GL_SAMPLE_POSITION                0x8E50
#define GL_SAMPLE_MASK                    0x8E51
#define GL_SAMPLE_MASK_VALUE              0x8E52
#define GL_MAX_SAMPLE_MASK_WORDS          0x8E59
#define GL_TEXTURE_2D_MULTISAMPLE         0x9100
#define GL_PROXY_TEXTURE_2D_MULTISAMPLE   0x9101
#define GL_TEXTURE_2D_MULTISAMPLE_ARRAY   0x9102
#define GL_PROXY_TEXTURE_2D_MULTISAMPLE_ARRAY 0x9103
#define GL_TEXTURE_BINDING_2D_MULTISAMPLE 0x9104
#define GL_TEXTURE_BINDING_2D_MULTISAMPLE_ARRAY 0x9105
#define GL_TEXTURE_SAMPLES                0x9106
#define GL_TEXTURE_FIXED_SAMPLE_LOCATIONS 0x9107
#define GL_SAMPLER_2D_MULTISAMPLE         0x9108
#define GL_INT_SAMPLER_2D_MULTISAMPLE     0x9109
#define GL_UNSIGNED_INT_SAMPLER_2D_MULTISAMPLE 0x910A
#define GL_SAMPLER_2D_MULTISAMPLE_ARRAY   0x910B
#define GL_INT_SAMPLER_2D_MULTISAMPLE_ARRAY 0x910C
#define GL_UNSIGNED_INT_SAMPLER_2D_MULTISAMPLE_ARRAY 0x910D
#define GL_MAX_COLOR_TEXTURE_SAMPLES      0x910E
#define GL_MAX_DEPTH_TEXTURE_SAMPLES      0x910F
#define GL_MAX_INTEGER_SAMPLES            0x9110
typedef void (APIENTRYP PFNGLDRAWELEMENTSBASEVERTEXPROC) (GLenum mode, GLsizei count, GLenum type, const void *indices, GLint basevertex);
typedef void (APIENTRYP PFNGLDRAWRANGEELEMENTSBASEVERTEXPROC) (GLenum mode, GLuint start, GLuint end, GLsizei count, GLenum type, const void *indices, GLint basevertex);
typedef void (APIENTRYP PFNGLDRAWELEMENTSINSTANCEDBASEVERTEXPROC) (GLenum mode, GLsizei count, GLenum type, const void *indices, GLsizei instancecount, GLint basevertex);
typedef void (APIENTRYP PFNGLMULTIDRAWELEMENTSBASEVERTEXPROC) (GLenum mode, const GLsizei *count, GLenum type, const void *const*indices, GLsizei drawcount, const GLint *basevertex);
typedef void (APIENTRYP PFNGLPROVOKINGVERTEXPROC) (GLenum mode);
typedef GLsync (APIENTRYP PFNGLFENCESYNCPROC) (GLenum condition, GLbitfield flags);
typedef GLboolean (APIENTRYP PFNGLISSYNCPROC) (GLsync sync);
typedef void (APIENTRYP PFNGLDELETESYNCPROC) (GLsync sync);
typedef GLenum (APIENTRYP PFNGLCLIENTWAITSYNCPROC) (GLsync sync, GLbitfield flags, GLuint64 timeout);
typedef void (APIENTRYP PFNGLWAITSYNCPROC) (GLsync sync, GLbitfield flags, GLuint64 timeout);
typedef void (APIENTRYP PFNGLGETINTEGER64VPROC) (GLenum pname, GLint64 *data);
typedef void (APIENTRYP PFNGLGETSYNCIVPROC) (GLsync sync, GLenum pname, GLsizei bufSize, GLsizei *length, GLint *values);
typedef void (APIENTRYP PFNGLGETINTEGER64I_VPROC) (GLenum target, GLuint index, GLint64 *data);
typedef void (APIENTRYP PFNGLGETBUFFERPARAMETERI64VPROC) (GLenum target, GLenum pname, GLint64 *params);
typedef void (APIENTRYP PFNGLFRAMEBUFFERTEXTUREPROC) (GLenum target, GLenum attachment, GLuint texture, GLint level);
typedef void (APIENTRYP PFNGLTEXIMAGE2DMULTISAMPLEPROC) (GLenum target, GLsizei samples, GLenum internalformat, GLsizei width, GLsizei height, GLboolean fixedsamplelocations);
typedef void (APIENTRYP PFNGLTEXIMAGE3DMULTISAMPLEPROC) (GLenum target, GLsizei samples, GLenum internalformat, GLsizei width, GLsizei height, GLsizei depth, GLboolean fixedsamplelocations);
typedef void (APIENTRYP PFNGLGETMULTISAMPLEFVPROC) (GLenum pname, GLuint index, GLfloat *val);
typedef void (APIENTRYP PFNGLSAMPLEMASKIPROC) (GLuint maskNumber, GLbitfield mask);

#define GL_VERTEX_ATTRIB_ARRAY_DIVISOR    0x88FE
#define GL_SRC1_COLOR                     0x88F9
#define GL_ONE_MINUS_SRC1_COLOR           0x88FA
#define GL_ONE_MINUS_SRC1_ALPHA           0x88FB
#define GL_MAX_DUAL_SOURCE_DRAW_BUFFERS   0x88FC
#define GL_ANY_SAMPLES_PASSED             0x8C2F
#define GL_SAMPLER_BINDING                0x8919
#define GL_RGB10_A2UI                     0x906F
#define GL_TEXTURE_SWIZZLE_R              0x8E42
#define GL_TEXTURE_SWIZZLE_G              0x8E43
#define GL_TEXTURE_SWIZZLE_B              0x8E44
#define GL_TEXTURE_SWIZZLE_A              0x8E45
#define GL_TEXTURE_SWIZZLE_RGBA           0x8E46
#define GL_TIME_ELAPSED                   0x88BF
#define GL_TIMESTAMP                      0x8E28
#define GL_INT_2_10_10_10_REV             0x8D9F
typedef void (APIENTRYP PFNGLBINDFRAGDATALOCATIONINDEXEDPROC) (GLuint program, GLuint colorNumber, GLuint index, const GLchar *name);
typedef GLint (APIENTRYP PFNGLGETFRAGDATAINDEXPROC) (GLuint program, const GLchar *name);
typedef void (APIENTRYP PFNGLGENSAMPLERSPROC) (GLsizei count, GLuint *samplers);
typedef void (APIENTRYP PFNGLDELETESAMPLERSPROC) (GLsizei count, const GLuint *samplers);
typedef GLboolean (APIENTRYP PFNGLISSAMPLERPROC) (GLuint sampler);
typedef void (APIENTRYP PFNGLBINDSAMPLERPROC) (GLuint unit, GLuint sampler);
typedef void (APIENTRYP PFNGLSAMPLERPARAMETERIPROC) (GLuint sampler, GLenum pname, GLint param);
typedef void (APIENTRYP PFNGLSAMPLERPARAMETERIVPROC) (GLuint sampler, GLenum pname, const GLint *param);
typedef void (APIENTRYP PFNGLSAMPLERPARAMETERFPROC) (GLuint sampler, GLenum pname, GLfloat param);
typedef void (APIENTRYP PFNGLSAMPLERPARAMETERFVPROC) (GLuint sampler, GLenum pname, const GLfloat *param);
typedef void (APIENTRYP PFNGLSAMPLERPARAMETERIIVPROC) (GLuint sampler, GLenum pname, const GLint *param);
typedef void (APIENTRYP PFNGLSAMPLERPARAMETERIUIVPROC) (GLuint sampler, GLenum pname, const GLuint *param);
typedef void (APIENTRYP PFNGLGETSAMPLERPARAMETERIVPROC) (GLuint sampler, GLenum pname, GLint *params);
typedef void (APIENTRYP PFNGLGETSAMPLERPARAMETERIIVPROC) (GLuint sampler, GLenum pname, GLint *params);
typedef void (APIENTRYP PFNGLGETSAMPLERPARAMETERFVPROC) (GLuint sampler, GLenum pname, GLfloat *params);
typedef void (APIENTRYP PFNGLGETSAMPLERPARAMETERIUIVPROC) (GLuint sampler, GLenum pname, GLuint *params);
typedef void (APIENTRYP PFNGLQUERYCOUNTERPROC) (GLuint id, GLenum target);
typedef void (APIENTRYP PFNGLGETQUERYOBJECTI64VPROC) (GLuint id, GLenum pname, GLint64 *params);
typedef void (APIENTRYP PFNGLGETQUERYOBJECTUI64VPROC) (GLuint id, GLenum pname, GLuint64 *params);
typedef void (APIENTRYP PFNGLVERTEXATTRIBDIVISORPROC) (GLuint index, GLuint divisor);
typedef void (APIENTRYP PFNGLVERTEXATTRIBP1UIPROC) (GLuint index, GLenum type, GLboolean normalized, GLuint value);
typedef void (APIENTRYP PFNGLVERTEXATTRIBP1UIVPROC) (GLuint index, GLenum type, GLboolean normalized, const GLuint *value);
typedef void (APIENTRYP PFNGLVERTEXATTRIBP2UIPROC) (GLuint index, GLenum type, GLboolean normalized, GLuint value);
typedef void (APIENTRYP PFNGLVERTEXATTRIBP2UIVPROC) (GLuint index, GLenum type, GLboolean normalized, const GLuint *value);
typedef void (APIENTRYP PFNGLVERTEXATTRIBP3UIPROC) (GLuint index, GLenum type, GLboolean normalized, GLuint value);
typedef void (APIENTRYP PFNGLVERTEXATTRIBP3UIVPROC) (GLuint index, GLenum type, GLboolean normalized, const GLuint *value);
typedef void (APIENTRYP PFNGLVERTEXATTRIBP4UIPROC) (GLuint index, GLenum type, GLboolean normalized, GLuint value);
typedef void (APIENTRYP PFNGLVERTEXATTRIBP4UIVPROC) (GLuint index, GLenum type, GLboolean normalized, const GLuint *value);

#define GL_SAMPLE_SHADING                 0x8C36
#define GL_MIN_SAMPLE_SHADING_VALUE       0x8C37
#define GL_MIN_PROGRAM_TEXTURE_GATHER_OFFSET 0x8E5E
#define GL_MAX_PROGRAM_TEXTURE_GATHER_OFFSET 0x8E5F
#define GL_TEXTURE_CUBE_MAP_ARRAY         0x9009
#define GL_TEXTURE_BINDING_CUBE_MAP_ARRAY 0x900A
#define GL_PROXY_TEXTURE_CUBE_MAP_ARRAY   0x900B
#define GL_SAMPLER_CUBE_MAP_ARRAY         0x900C
#define GL_SAMPLER_CUBE_MAP_ARRAY_SHADOW  0x900D
#define GL_INT_SAMPLER_CUBE_MAP_ARRAY     0x900E
#define GL_UNSIGNED_INT_SAMPLER_CUBE_MAP_ARRAY 0x900F
#define GL_DRAW_INDIRECT_BUFFER           0x8F3F
#define GL_DRAW_INDIRECT_BUFFER_BINDING   0x8F43
#define GL_GEOMETRY_SHADER_INVOCATIONS    0x887F
#define GL_MAX_GEOMETRY_SHADER_INVOCATIONS 0x8E5A
#define GL_MIN_FRAGMENT_INTERPOLATION_OFFSET 0x8E5B
#define GL_MAX_FRAGMENT_INTERPOLATION_OFFSET 0x8E5C
#define GL_FRAGMENT_INTERPOLATION_OFFSET_BITS 0x8E5D
#define GL_MAX_VERTEX_STREAMS             0x8E71
#define GL_DOUBLE_VEC2                    0x8FFC
#define GL_DOUBLE_VEC3                    0x8FFD
#define GL_DOUBLE_VEC4                    0x8FFE
#define GL_DOUBLE_MAT2                    0x8F46
#define GL_DOUBLE_MAT3                    0x8F47
#define GL_DOUBLE_MAT4                    0x8F48
#define GL_DOUBLE_MAT2x3                  0x8F49
#define GL_DOUBLE_MAT2x4                  0x8F4A
#define GL_DOUBLE_MAT3x2                  0x8F4B
#define GL_DOUBLE_MAT3x4                  0x8F4C
#define GL_DOUBLE_MAT4x2                  0x8F4D
#define GL_DOUBLE_MAT4x3                  0x8F4E
#define GL_ACTIVE_SUBROUTINES             0x8DE5
#define GL_ACTIVE_SUBROUTINE_UNIFORMS     0x8DE6
#define GL_ACTIVE_SUBROUTINE_UNIFORM_LOCATIONS 0x8E47
#define GL_ACTIVE_SUBROUTINE_MAX_LENGTH   0x8E48
#define GL_ACTIVE_SUBROUTINE_UNIFORM_MAX_LENGTH 0x8E49
#define GL_MAX_SUBROUTINES                0x8DE7
#define GL_MAX_SUBROUTINE_UNIFORM_LOCATIONS 0x8DE8
#define GL_NUM_COMPATIBLE_SUBROUTINES     0x8E4A
#define GL_COMPATIBLE_SUBROUTINES         0x8E4B
#define GL_PATCHES                        0x000E
#define GL_PATCH_VERTICES                 0x8E72
#define GL_PATCH_DEFAULT_INNER_LEVEL      0x8E73
#define GL_PATCH_DEFAULT_OUTER_LEVEL      0x8E74
#define GL_TESS_CONTROL_OUTPUT_VERTICES   0x8E75
#define GL_TESS_GEN_MODE                  0x8E76
#define GL_TESS_GEN_SPACING               0x8E77
#define GL_TESS_GEN_VERTEX_ORDER          0x8E78
#define GL_TESS_GEN_POINT_MODE            0x8E79
#define GL_ISOLINES                       0x8E7A
#define GL_FRACTIONAL_ODD                 0x8E7B
#define GL_FRACTIONAL_EVEN                0x8E7C
#define GL_MAX_PATCH_VERTICES             0x8E7D
#define GL_MAX_TESS_GEN_LEVEL             0x8E7E
#define GL_MAX_TESS_CONTROL_UNIFORM_COMPONENTS 0x8E7F
#define GL_MAX_TESS_EVALUATION_UNIFORM_COMPONENTS 0x8E80
#define GL_MAX_TESS_CONTROL_TEXTURE_IMAGE_UNITS 0x8E81
#define GL_MAX_TESS_EVALUATION_TEXTURE_IMAGE_UNITS 0x8E82
#define GL_MAX_TESS_CONTROL_OUTPUT_COMPONENTS 0x8E83
#define GL_MAX_TESS_PATCH_COMPONENTS      0x8E84
#define GL_MAX_TESS_CONTROL_TOTAL_OUTPUT_COMPONENTS 0x8E85
#define GL_MAX_TESS_EVALUATION_OUTPUT_COMPONENTS 0x8E86
#define GL_MAX_TESS_CONTROL_UNIFORM_BLOCKS 0x8E89
#define GL_MAX_TESS_EVALUATION_UNIFORM_BLOCKS 0x8E8A
#define GL_MAX_TESS_CONTROL_INPUT_COMPONENTS 0x886C
#define GL_MAX_TESS_EVALUATION_INPUT_COMPONENTS 0x886D
#define GL_MAX_COMBINED_TESS_CONTROL_UNIFORM_COMPONENTS 0x8E1E
#define GL_MAX_COMBINED_TESS_EVALUATION_UNIFORM_COMPONENTS 0x8E1F
#define GL_UNIFORM_BLOCK_REFERENCED_BY_TESS_CONTROL_SHADER 0x84F0
#define GL_UNIFORM_BLOCK_REFERENCED_BY_TESS_EVALUATION_SHADER 0x84F1
#define GL_TESS_EVALUATION_SHADER         0x8E87
#define GL_TESS_CONTROL_SHADER            0x8E88
#define GL_TRANSFORM_FEEDBACK             0x8E22
#define GL_TRANSFORM_FEEDBACK_BUFFER_PAUSED 0x8E23
#define GL_TRANSFORM_FEEDBACK_BUFFER_ACTIVE 0x8E24
#define GL_TRANSFORM_FEEDBACK_BINDING     0x8E25
#define GL_MAX_TRANSFORM_FEEDBACK_BUFFERS 0x8E70
typedef void (APIENTRYP PFNGLMINSAMPLESHADINGPROC) (GLfloat value);
typedef void (APIENTRYP PFNGLBLENDEQUATIONIPROC) (GLuint buf, GLenum mode);
typedef void (APIENTRYP PFNGLBLENDEQUATIONSEPARATEIPROC) (GLuint buf, GLenum modeRGB, GLenum modeAlpha);
typedef void (APIENTRYP PFNGLBLENDFUNCIPROC) (GLuint buf, GLenum src, GLenum dst);
typedef void (APIENTRYP PFNGLBLENDFUNCSEPARATEIPROC) (GLuint buf, GLenum srcRGB, GLenum dstRGB, GLenum srcAlpha, GLenum dstAlpha);
typedef void (APIENTRYP PFNGLDRAWARRAYSINDIRECTPROC) (GLenum mode, const void *indirect);
typedef void (APIENTRYP PFNGLDRAWELEMENTSINDIRECTPROC) (GLenum mode, GLenum type, const void *indirect);
typedef void (APIENTRYP PFNGLUNIFORM1DPROC) (GLint location, GLdouble x);
typedef void (APIENTRYP PFNGLUNIFORM2DPROC) (GLint location, GLdouble x, GLdouble y);
typedef void (APIENTRYP PFNGLUNIFORM3DPROC) (GLint location, GLdouble x, GLdouble y, GLdouble z);
typedef void (APIENTRYP PFNGLUNIFORM4DPROC) (GLint location, GLdouble x, GLdouble y, GLdouble z, GLdouble w);
typedef void (APIENTRYP PFNGLUNIFORM1DVPROC) (GLint location, GLsizei count, const GLdouble *value);
typedef void (APIENTRYP PFNGLUNIFORM2DVPROC) (GLint location, GLsizei count, const GLdouble *value);
typedef void (APIENTRYP PFNGLUNIFORM3DVPROC) (GLint location, GLsizei count, const GLdouble *value);
typedef void (APIENTRYP PFNGLUNIFORM4DVPROC) (GLint location, GLsizei count, const GLdouble *value);
typedef void (APIENTRYP PFNGLUNIFORMMATRIX2DVPROC) (GLint location, GLsizei count, GLboolean transpose, const GLdouble *value);
typedef void (APIENTRYP PFNGLUNIFORMMATRIX3DVPROC) (GLint location, GLsizei count, GLboolean transpose, const GLdouble *value);
typedef void (APIENTRYP PFNGLUNIFORMMATRIX4DVPROC) (GLint location, GLsizei count, GLboolean transpose, const GLdouble *value);
typedef void (APIENTRYP PFNGLUNIFORMMATRIX2X3DVPROC) (GLint location, GLsizei count, GLboolean transpose, const GLdouble *value);
typedef void (APIENTRYP PFNGLUNIFORMMATRIX2X4DVPROC) (GLint location, GLsizei count, GLboolean transpose, const GLdouble *value);
typedef void (APIENTRYP PFNGLUNIFORMMATRIX3X2DVPROC) (GLint location, GLsizei count, GLboolean transpose, const GLdouble *value);
typedef void (APIENTRYP PFNGLUNIFORMMATRIX3X4DVPROC) (GLint location, GLsizei count, GLboolean transpose, const GLdouble *value);
typedef void (APIENTRYP PFNGLUNIFORMMATRIX4X2DVPROC) (GLint location, GLsizei count, GLboolean transpose, const GLdouble *value);
typedef void (APIENTRYP PFNGLUNIFORMMATRIX4X3DVPROC) (GLint location, GLsizei count, GLboolean transpose, const GLdouble *value);
typedef void (APIENTRYP PFNGLGETUNIFORMDVPROC) (GLuint program, GLint location, GLdouble *params);
typedef GLint (APIENTRYP PFNGLGETSUBROUTINEUNIFORMLOCATIONPROC) (GLuint program, GLenum shadertype, const GLchar *name);
typedef GLuint (APIENTRYP PFNGLGETSUBROUTINEINDEXPROC) (GLuint program, GLenum shadertype, const GLchar *name);
typedef void (APIENTRYP PFNGLGETACTIVESUBROUTINEUNIFORMIVPROC) (GLuint program, GLenum shadertype, GLuint index, GLenum pname, GLint *values);
typedef void (APIENTRYP PFNGLGETACTIVESUBROUTINEUNIFORMNAMEPROC) (GLuint program, GLenum shadertype, GLuint index, GLsizei bufsize, GLsizei *length, GLchar *name);
typedef void (APIENTRYP PFNGLGETACTIVESUBROUTINENAMEPROC) (GLuint program, GLenum shadertype, GLuint index, GLsizei bufsize, GLsizei *length, GLchar *name);
typedef void (APIENTRYP PFNGLUNIFORMSUBROUTINESUIVPROC) (GLenum shadertype, GLsizei count, const GLuint *indices);
typedef void (APIENTRYP PFNGLGETUNIFORMSUBROUTINEUIVPROC) (GLenum shadertype, GLint location, GLuint *params);
typedef void (APIENTRYP PFNGLGETPROGRAMSTAGEIVPROC) (GLuint program, GLenum shadertype, GLenum pname, GLint *values);
typedef void (APIENTRYP PFNGLPATCHPARAMETERIPROC) (GLenum pname, GLint value);
typedef void (APIENTRYP PFNGLPATCHPARAMETERFVPROC) (GLenum pname, const GLfloat *values);
typedef void (APIENTRYP PFNGLBINDTRANSFORMFEEDBACKPROC) (GLenum target, GLuint id);
typedef void (APIENTRYP PFNGLDELETETRANSFORMFEEDBACKSPROC) (GLsizei n, const GLuint *ids);
typedef void (APIENTRYP PFNGLGENTRANSFORMFEEDBACKSPROC) (GLsizei n, GLuint *ids);
typedef GLboolean (APIENTRYP PFNGLISTRANSFORMFEEDBACKPROC) (GLuint id);
typedef void (APIENTRYP PFNGLPAUSETRANSFORMFEEDBACKPROC) (void);
typedef void (APIENTRYP PFNGLRESUMETRANSFORMFEEDBACKPROC) (void);
typedef void (APIENTRYP PFNGLDRAWTRANSFORMFEEDBACKPROC) (GLenum mode, GLuint id);
typedef void (APIENTRYP PFNGLDRAWTRANSFORMFEEDBACKSTREAMPROC) (GLenum mode, GLuint id, GLuint stream);
typedef void (APIENTRYP PFNGLBEGINQUERYINDEXEDPROC) (GLenum target, GLuint index, GLuint id);
typedef void (APIENTRYP PFNGLENDQUERYINDEXEDPROC) (GLenum target, GLuint index);
typedef void (APIENTRYP PFNGLGETQUERYINDEXEDIVPROC) (GLenum target, GLuint index, GLenum pname, GLint *params);

#define GL_FIXED                          0x140C
#define GL_IMPLEMENTATION_COLOR_READ_TYPE 0x8B9A
#define GL_IMPLEMENTATION_COLOR_READ_FORMAT 0x8B9B
#define GL_LOW_FLOAT                      0x8DF0
#define GL_MEDIUM_FLOAT                   0x8DF1
#define GL_HIGH_FLOAT                     0x8DF2
#define GL_LOW_INT                        0x8DF3
#define GL_MEDIUM_INT                     0x8DF4
#define GL_HIGH_INT                       0x8DF5
#define GL_SHADER_COMPILER                0x8DFA
#define GL_SHADER_BINARY_FORMATS          0x8DF8
#define GL_NUM_SHADER_BINARY_FORMATS      0x8DF9
#define GL_MAX_VERTEX_UNIFORM_VECTORS     0x8DFB
#define GL_MAX_VARYING_VECTORS            0x8DFC
#define GL_MAX_FRAGMENT_UNIFORM_VECTORS   0x8DFD
#define GL_RGB565                         0x8D62
#define GL_PROGRAM_BINARY_RETRIEVABLE_HINT 0x8257
#define GL_PROGRAM_BINARY_LENGTH          0x8741
#define GL_NUM_PROGRAM_BINARY_FORMATS     0x87FE
#define GL_PROGRAM_BINARY_FORMATS         0x87FF
#define GL_VERTEX_SHADER_BIT              0x00000001
#define GL_FRAGMENT_SHADER_BIT            0x00000002
#define GL_GEOMETRY_SHADER_BIT            0x00000004
#define GL_TESS_CONTROL_SHADER_BIT        0x00000008
#define GL_TESS_EVALUATION_SHADER_BIT     0x00000010
#define GL_ALL_SHADER_BITS                0xFFFFFFFF
#define GL_PROGRAM_SEPARABLE              0x8258
#define GL_ACTIVE_PROGRAM                 0x8259
#define GL_PROGRAM_PIPELINE_BINDING       0x825A
#define GL_MAX_VIEWPORTS                  0x825B
#define GL_VIEWPORT_SUBPIXEL_BITS         0x825C
#define GL_VIEWPORT_BOUNDS_RANGE          0x825D
#define GL_LAYER_PROVOKING_VERTEX         0x825E
#define GL_VIEWPORT_INDEX_PROVOKING_VERTEX 0x825F
#define GL_UNDEFINED_VERTEX               0x8260
typedef void (APIENTRYP PFNGLRELEASESHADERCOMPILERPROC) (void);
typedef void (APIENTRYP PFNGLSHADERBINARYPROC) (GLsizei count, const GLuint *shaders, GLenum binaryformat, const void *binary, GLsizei length);
typedef void (APIENTRYP PFNGLGETSHADERPRECISIONFORMATPROC) (GLenum shadertype, GLenum precisiontype, GLint *range, GLint *precision);
typedef void (APIENTRYP PFNGLDEPTHRANGEFPROC) (GLfloat n, GLfloat f);
typedef void (APIENTRYP PFNGLCLEARDEPTHFPROC) (GLfloat d);
typedef void (APIENTRYP PFNGLGETPROGRAMBINARYPROC) (GLuint program, GLsizei bufSize, GLsizei *length, GLenum *binaryFormat, void *binary);
typedef void (APIENTRYP PFNGLPROGRAMBINARYPROC) (GLuint program, GLenum binaryFormat, const void *binary, GLsizei length);
typedef void (APIENTRYP PFNGLPROGRAMPARAMETERIPROC) (GLuint program, GLenum pname, GLint value);
typedef void (APIENTRYP PFNGLUSEPROGRAMSTAGESPROC) (GLuint pipeline, GLbitfield stages, GLuint program);
typedef void (APIENTRYP PFNGLACTIVESHADERPROGRAMPROC) (GLuint pipeline, GLuint program);
typedef GLuint (APIENTRYP PFNGLCREATESHADERPROGRAMVPROC) (GLenum type, GLsizei count, const GLchar *const*strings);
typedef void (APIENTRYP PFNGLBINDPROGRAMPIPELINEPROC) (GLuint pipeline);
typedef void (APIENTRYP PFNGLDELETEPROGRAMPIPELINESPROC) (GLsizei n, const GLuint *pipelines);
typedef void (APIENTRYP PFNGLGENPROGRAMPIPELINESPROC) (GLsizei n, GLuint *pipelines);
typedef GLboolean (APIENTRYP PFNGLISPROGRAMPIPELINEPROC) (GLuint pipeline);
typedef void (APIENTRYP PFNGLGETPROGRAMPIPELINEIVPROC) (GLuint pipeline, GLenum pname, GLint *params);
typedef void (APIENTRYP PFNGLPROGRAMUNIFORM1IPROC) (GLuint program, GLint location, GLint v0);
typedef void (APIENTRYP PFNGLPROGRAMUNIFORM1IVPROC) (GLuint program, GLint location, GLsizei count, const GLint *value);
typedef void (APIENTRYP PFNGLPROGRAMUNIFORM1FPROC) (GLuint program, GLint location, GLfloat v0);
typedef void (APIENTRYP PFNGLPROGRAMUNIFORM1FVPROC) (GLuint program, GLint location, GLsizei count, const GLfloat *value);
typedef void (APIENTRYP PFNGLPROGRAMUNIFORM1DPROC) (GLuint program, GLint location, GLdouble v0);
typedef void (APIENTRYP PFNGLPROGRAMUNIFORM1DVPROC) (GLuint program, GLint location, GLsizei count, const GLdouble *value);
typedef void (APIENTRYP PFNGLPROGRAMUNIFORM1UIPROC) (GLuint program, GLint location, GLuint v0);
typedef void (APIENTRYP PFNGLPROGRAMUNIFORM1UIVPROC) (GLuint program, GLint location, GLsizei count, const GLuint *value);
typedef void (APIENTRYP PFNGLPROGRAMUNIFORM2IPROC) (GLuint program, GLint location, GLint v0, GLint v1);
typedef void (APIENTRYP PFNGLPROGRAMUNIFORM2IVPROC) (GLuint program, GLint location, GLsizei count, const GLint *value);
typedef void (APIENTRYP PFNGLPROGRAMUNIFORM2FPROC) (GLuint program, GLint location, GLfloat v0, GLfloat v1);
typedef void (APIENTRYP PFNGLPROGRAMUNIFORM2FVPROC) (GLuint program, GLint location, GLsizei count, const GLfloat *value);
typedef void (APIENTRYP PFNGLPROGRAMUNIFORM2DPROC) (GLuint program, GLint location, GLdouble v0, GLdouble v1);
typedef void (APIENTRYP PFNGLPROGRAMUNIFORM2DVPROC) (GLuint program, GLint location, GLsizei count, const GLdouble *value);
typedef void (APIENTRYP PFNGLPROGRAMUNIFORM2UIPROC) (GLuint program, GLint location, GLuint v0, GLuint v1);
typedef void (APIENTRYP PFNGLPROGRAMUNIFORM2UIVPROC) (GLuint program, GLint location, GLsizei count, const GLuint *value);
typedef void (APIENTRYP PFNGLPROGRAMUNIFORM3IPROC) (GLuint program, GLint location, GLint v0, GLint v1, GLint v2);
typedef void (APIENTRYP PFNGLPROGRAMUNIFORM3IVPROC) (GLuint program, GLint location, GLsizei count, const GLint *value);
typedef void (APIENTRYP PFNGLPROGRAMUNIFORM3FPROC) (GLuint program, GLint location, GLfloat v0, GLfloat v1, GLfloat v2);
typedef void (APIENTRYP PFNGLPROGRAMUNIFORM3FVPROC) (GLuint program, GLint location, GLsizei count, const GLfloat *value);
typedef void (APIENTRYP PFNGLPROGRAMUNIFORM3DPROC) (GLuint program, GLint location, GLdouble v0, GLdouble v1, GLdouble v2);
typedef void (APIENTRYP PFNGLPROGRAMUNIFORM3DVPROC) (GLuint program, GLint location, GLsizei count, const GLdouble *value);
typedef void (APIENTRYP PFNGLPROGRAMUNIFORM3UIPROC) (GLuint program, GLint location, GLuint v0, GLuint v1, GLuint v2);
typedef void (APIENTRYP PFNGLPROGRAMUNIFORM3UIVPROC) (GLuint program, GLint location, GLsizei count, const GLuint *value);
typedef void (APIENTRYP PFNGLPROGRAMUNIFORM4IPROC) (GLuint program, GLint location, GLint v0, GLint v1, GLint v2, GLint v3);
typedef void (APIENTRYP PFNGLPROGRAMUNIFORM4IVPROC) (GLuint program, GLint location, GLsizei count, const GLint *value);
typedef void (APIENTRYP PFNGLPROGRAMUNIFORM4FPROC) (GLuint program, GLint location, GLfloat v0, GLfloat v1, GLfloat v2, GLfloat v3);
typedef void (APIENTRYP PFNGLPROGRAMUNIFORM4FVPROC) (GLuint program, GLint location, GLsizei count, const GLfloat *value);
typedef void (APIENTRYP PFNGLPROGRAMUNIFORM4DPROC) (GLuint program, GLint location, GLdouble v0, GLdouble v1, GLdouble v2, GLdouble v3);
typedef void (APIENTRYP PFNGLPROGRAMUNIFORM4DVPROC) (GLuint program, GLint location, GLsizei count, const GLdouble *value);
typedef void (APIENTRYP PFNGLPROGRAMUNIFORM4UIPROC) (GLuint program, GLint location, GLuint v0, GLuint v1, GLuint v2, GLuint v3);
typedef void (APIENTRYP PFNGLPROGRAMUNIFORM4UIVPROC) (GLuint program, GLint location, GLsizei count, const GLuint *value);
typedef void (APIENTRYP PFNGLPROGRAMUNIFORMMATRIX2FVPROC) (GLuint program, GLint location, GLsizei count, GLboolean transpose, const GLfloat *value);
typedef void (APIENTRYP PFNGLPROGRAMUNIFORMMATRIX3FVPROC) (GLuint program, GLint location, GLsizei count, GLboolean transpose, const GLfloat *value);
typedef void (APIENTRYP PFNGLPROGRAMUNIFORMMATRIX4FVPROC) (GLuint program, GLint location, GLsizei count, GLboolean transpose, const GLfloat *value);
typedef void (APIENTRYP PFNGLPROGRAMUNIFORMMATRIX2DVPROC) (GLuint program, GLint location, GLsizei count, GLboolean transpose, const GLdouble *value);
typedef void (APIENTRYP PFNGLPROGRAMUNIFORMMATRIX3DVPROC) (GLuint program, GLint location, GLsizei count, GLboolean transpose, const GLdouble *value);
typedef void (APIENTRYP PFNGLPROGRAMUNIFORMMATRIX4DVPROC) (GLuint program, GLint location, GLsizei count, GLboolean transpose, const GLdouble *value);
typedef void (APIENTRYP PFNGLPROGRAMUNIFORMMATRIX2X3FVPROC) (GLuint program, GLint location, GLsizei count, GLboolean transpose, const GLfloat *value);
typedef void (APIENTRYP PFNGLPROGRAMUNIFORMMATRIX3X2FVPROC) (GLuint program, GLint location, GLsizei count, GLboolean transpose, const GLfloat *value);
typedef void (APIENTRYP PFNGLPROGRAMUNIFORMMATRIX2X4FVPROC) (GLuint program, GLint location, GLsizei count, GLboolean transpose, const GLfloat *value);
typedef void (APIENTRYP PFNGLPROGRAMUNIFORMMATRIX4X2FVPROC) (GLuint program, GLint location, GLsizei count, GLboolean transpose, const GLfloat *value);
typedef void (APIENTRYP PFNGLPROGRAMUNIFORMMATRIX3X4FVPROC) (GLuint program, GLint location, GLsizei count, GLboolean transpose, const GLfloat *value);
typedef void (APIENTRYP PFNGLPROGRAMUNIFORMMATRIX4X3FVPROC) (GLuint program, GLint location, GLsizei count, GLboolean transpose, const GLfloat *value);
typedef void (APIENTRYP PFNGLPROGRAMUNIFORMMATRIX2X3DVPROC) (GLuint program, GLint location, GLsizei count, GLboolean transpose, const GLdouble *value);
typedef void (APIENTRYP PFNGLPROGRAMUNIFORMMATRIX3X2DVPROC) (GLuint program, GLint location, GLsizei count, GLboolean transpose, const GLdouble *value);
typedef void (APIENTRYP PFNGLPROGRAMUNIFORMMATRIX2X4DVPROC) (GLuint program, GLint location, GLsizei count, GLboolean transpose, const GLdouble *value);
typedef void (APIENTRYP PFNGLPROGRAMUNIFORMMATRIX4X2DVPROC) (GLuint program, GLint location, GLsizei count, GLboolean transpose, const GLdouble *value);
typedef void (APIENTRYP PFNGLPROGRAMUNIFORMMATRIX3X4DVPROC) (GLuint program, GLint location, GLsizei count, GLboolean transpose, const GLdouble *value);
typedef void (APIENTRYP PFNGLPROGRAMUNIFORMMATRIX4X3DVPROC) (GLuint program, GLint location, GLsizei count, GLboolean transpose, const GLdouble *value);
typedef void (APIENTRYP PFNGLVALIDATEPROGRAMPIPELINEPROC) (GLuint pipeline);
typedef void (APIENTRYP PFNGLGETPROGRAMPIPELINEINFOLOGPROC) (GLuint pipeline, GLsizei bufSize, GLsizei *length, GLchar *infoLog);
typedef void (APIENTRYP PFNGLVERTEXATTRIBL1DPROC) (GLuint index, GLdouble x);
typedef void (APIENTRYP PFNGLVERTEXATTRIBL2DPROC) (GLuint index, GLdouble x, GLdouble y);
typedef void (APIENTRYP PFNGLVERTEXATTRIBL3DPROC) (GLuint index, GLdouble x, GLdouble y, GLdouble z);
typedef void (APIENTRYP PFNGLVERTEXATTRIBL4DPROC) (GLuint index, GLdouble x, GLdouble y, GLdouble z, GLdouble w);
typedef void (APIENTRYP PFNGLVERTEXATTRIBL1DVPROC) (GLuint index, const GLdouble *v);
typedef void (APIENTRYP PFNGLVERTEXATTRIBL2DVPROC) (GLuint index, const GLdouble *v);
typedef void (APIENTRYP PFNGLVERTEXATTRIBL3DVPROC) (GLuint index, const GLdouble *v);
typedef void (APIENTRYP PFNGLVERTEXATTRIBL4DVPROC) (GLuint index, const GLdouble *v);
typedef void (APIENTRYP PFNGLVERTEXATTRIBLPOINTERPROC) (GLuint index, GLint size, GLenum type, GLsizei stride, const void *pointer);
typedef void (APIENTRYP PFNGLGETVERTEXATTRIBLDVPROC) (GLuint index, GLenum pname, GLdouble *params);
typedef void (APIENTRYP PFNGLVIEWPORTARRAYVPROC) (GLuint first, GLsizei count, const GLfloat *v);
typedef void (APIENTRYP PFNGLVIEWPORTINDEXEDFPROC) (GLuint index, GLfloat x, GLfloat y, GLfloat w, GLfloat h);
typedef void (APIENTRYP PFNGLVIEWPORTINDEXEDFVPROC) (GLuint index, const GLfloat *v);
typedef void (APIENTRYP PFNGLSCISSORARRAYVPROC) (GLuint first, GLsizei count, const GLint *v);
typedef void (APIENTRYP PFNGLSCISSORINDEXEDPROC) (GLuint index, GLint left, GLint bottom, GLsizei width, GLsizei height);
typedef void (APIENTRYP PFNGLSCISSORINDEXEDVPROC) (GLuint index, const GLint *v);
typedef void (APIENTRYP PFNGLDEPTHRANGEARRAYVPROC) (GLuint first, GLsizei count, const GLdouble *v);
typedef void (APIENTRYP PFNGLDEPTHRANGEINDEXEDPROC) (GLuint index, GLdouble n, GLdouble f);
typedef void (APIENTRYP PFNGLGETFLOATI_VPROC) (GLenum target, GLuint index, GLfloat *data);
typedef void (APIENTRYP PFNGLGETDOUBLEI_VPROC) (GLenum target, GLuint index, GLdouble *data);

#define GL_UNPACK_COMPRESSED_BLOCK_WIDTH  0x9127
#define GL_UNPACK_COMPRESSED_BLOCK_HEIGHT 0x9128
#define GL_UNPACK_COMPRESSED_BLOCK_DEPTH  0x9129
#define GL_UNPACK_COMPRESSED_BLOCK_SIZE   0x912A
#define GL_PACK_COMPRESSED_BLOCK_WIDTH    0x912B
#define GL_PACK_COMPRESSED_BLOCK_HEIGHT   0x912C
#define GL_PACK_COMPRESSED_BLOCK_DEPTH    0x912D
#define GL_PACK_COMPRESSED_BLOCK_SIZE     0x912E
#define GL_NUM_SAMPLE_COUNTS              0x9380
#define GL_MIN_MAP_BUFFER_ALIGNMENT       0x90BC
#define GL_ATOMIC_COUNTER_BUFFER          0x92C0
#define GL_ATOMIC_COUNTER_BUFFER_BINDING  0x92C1
#define GL_ATOMIC_COUNTER_BUFFER_START    0x92C2
#define GL_ATOMIC_COUNTER_BUFFER_SIZE     0x92C3
#define GL_ATOMIC_COUNTER_BUFFER_DATA_SIZE 0x92C4
#define GL_ATOMIC_COUNTER_BUFFER_ACTIVE_ATOMIC_COUNTERS 0x92C5
#define GL_ATOMIC_COUNTER_BUFFER_ACTIVE_ATOMIC_COUNTER_INDICES 0x92C6
#define GL_ATOMIC_COUNTER_BUFFER_REFERENCED_BY_VERTEX_SHADER 0x92C7
#define GL_ATOMIC_COUNTER_BUFFER_REFERENCED_BY_TESS_CONTROL_SHADER 0x92C8
#define GL_ATOMIC_COUNTER_BUFFER_REFERENCED_BY_TESS_EVALUATION_SHADER 0x92C9
#define GL_ATOMIC_COUNTER_BUFFER_REFERENCED_BY_GEOMETRY_SHADER 0x92CA
#define GL_ATOMIC_COUNTER_BUFFER_REFERENCED_BY_FRAGMENT_SHADER 0x92CB
#define GL_MAX_VERTEX_ATOMIC_COUNTER_BUFFERS 0x92CC
#define GL_MAX_TESS_CONTROL_ATOMIC_COUNTER_BUFFERS 0x92CD
#define GL_MAX_TESS_EVALUATION_ATOMIC_COUNTER_BUFFERS 0x92CE
#define GL_MAX_GEOMETRY_ATOMIC_COUNTER_BUFFERS 0x92CF
#define GL_MAX_FRAGMENT_ATOMIC_COUNTER_BUFFERS 0x92D0
#define GL_MAX_COMBINED_ATOMIC_COUNTER_BUFFERS 0x92D1
#define GL_MAX_VERTEX_ATOMIC_COUNTERS     0x92D2
#define GL_MAX_TESS_CONTROL_ATOMIC_COUNTERS 0x92D3
#define GL_MAX_TESS_EVALUATION_ATOMIC_COUNTERS 0x92D4
#define GL_MAX_GEOMETRY_ATOMIC_COUNTERS   0x92D5
#define GL_MAX_FRAGMENT_ATOMIC_COUNTERS   0x92D6
#define GL_MAX_COMBINED_ATOMIC_COUNTERS   0x92D7
#define GL_MAX_ATOMIC_COUNTER_BUFFER_SIZE 0x92D8
#define GL_MAX_ATOMIC_COUNTER_BUFFER_BINDINGS 0x92DC
#define GL_ACTIVE_ATOMIC_COUNTER_BUFFERS  0x92D9
#define GL_UNIFORM_ATOMIC_COUNTER_BUFFER_INDEX 0x92DA
#define GL_UNSIGNED_INT_ATOMIC_COUNTER    0x92DB
#define GL_VERTEX_ATTRIB_ARRAY_BARRIER_BIT 0x00000001
#define GL_ELEMENT_ARRAY_BARRIER_BIT      0x00000002
#define GL_UNIFORM_BARRIER_BIT            0x00000004
#define GL_TEXTURE_FETCH_BARRIER_BIT      0x00000008
#define GL_SHADER_IMAGE_ACCESS_BARRIER_BIT 0x00000020
#define GL_COMMAND_BARRIER_BIT            0x00000040
#define GL_PIXEL_BUFFER_BARRIER_BIT       0x00000080
#define GL_TEXTURE_UPDATE_BARRIER_BIT     0x00000100
#define GL_BUFFER_UPDATE_BARRIER_BIT      0x00000200
#define GL_FRAMEBUFFER_BARRIER_BIT        0x00000400
#define GL_TRANSFORM_FEEDBACK_BARRIER_BIT 0x00000800
#define GL_ATOMIC_COUNTER_BARRIER_BIT     0x00001000
#define GL_ALL_BARRIER_BITS               0xFFFFFFFF
#define GL_MAX_IMAGE_UNITS                0x8F38
#define GL_MAX_COMBINED_IMAGE_UNITS_AND_FRAGMENT_OUTPUTS 0x8F39
#define GL_IMAGE_BINDING_NAME             0x8F3A
#define GL_IMAGE_BINDING_LEVEL            0x8F3B
#define GL_IMAGE_BINDING_LAYERED          0x8F3C
#define GL_IMAGE_BINDING_LAYER            0x8F3D
#define GL_IMAGE_BINDING_ACCESS           0x8F3E
#define GL_IMAGE_1D                       0x904C
#define GL_IMAGE_2D                       0x904D
#define GL_IMAGE_3D                       0x904E
#define GL_IMAGE_2D_RECT                  0x904F
#define GL_IMAGE_CUBE                     0x9050
#define GL_IMAGE_BUFFER                   0x9051
#define GL_IMAGE_1D_ARRAY                 0x9052
#define GL_IMAGE_2D_ARRAY                 0x9053
#define GL_IMAGE_CUBE_MAP_ARRAY           0x9054
#define GL_IMAGE_2D_MULTISAMPLE           0x9055
#define GL_IMAGE_2D_MULTISAMPLE_ARRAY     0x9056
#define GL_INT_IMAGE_1D                   0x9057
#define GL_INT_IMAGE_2D                   0x9058
#define GL_INT_IMAGE_3D                   0x9059
#define GL_INT_IMAGE_2D_RECT              0x905A
#define GL_INT_IMAGE_CUBE                 0x905B
#define GL_INT_IMAGE_BUFFER               0x905C
#define GL_INT_IMAGE_1D_ARRAY             0x905D
#define GL_INT_IMAGE_2D_ARRAY             0x905E
#define GL_INT_IMAGE_CUBE_MAP_ARRAY       0x905F
#define GL_INT_IMAGE_2D_MULTISAMPLE       0x9060
#define GL_INT_IMAGE_2D_MULTISAMPLE_ARRAY 0x9061
#define GL_UNSIGNED_INT_IMAGE_1D          0x9062
#define GL_UNSIGNED_INT_IMAGE_2D          0x9063
#define GL_UNSIGNED_INT_IMAGE_3D          0x9064
#define GL_UNSIGNED_INT_IMAGE_2D_RECT     0x9065
#define GL_UNSIGNED_INT_IMAGE_CUBE        0x9066
#define GL_UNSIGNED_INT_IMAGE_BUFFER      0x9067
#define GL_UNSIGNED_INT_IMAGE_1D_ARRAY    0x9068
#define GL_UNSIGNED_INT_IMAGE_2D_ARRAY    0x9069
#define GL_UNSIGNED_INT_IMAGE_CUBE_MAP_ARRAY 0x906A
#define GL_UNSIGNED_INT_IMAGE_2D_MULTISAMPLE 0x906B
#define GL_UNSIGNED_INT_IMAGE_2D_MULTISAMPLE_ARRAY 0x906C
#define GL_MAX_IMAGE_SAMPLES              0x906D
#define GL_IMAGE_BINDING_FORMAT           0x906E
#define GL_IMAGE_FORMAT_COMPATIBILITY_TYPE 0x90C7
#define GL_IMAGE_FORMAT_COMPATIBILITY_BY_SIZE 0x90C8
#define GL_IMAGE_FORMAT_COMPATIBILITY_BY_CLASS 0x90C9
#define GL_MAX_VERTEX_IMAGE_UNIFORMS      0x90CA
#define GL_MAX_TESS_CONTROL_IMAGE_UNIFORMS 0x90CB
#define GL_MAX_TESS_EVALUATION_IMAGE_UNIFORMS 0x90CC
#define GL_MAX_GEOMETRY_IMAGE_UNIFORMS    0x90CD
#define GL_MAX_FRAGMENT_IMAGE_UNIFORMS    0x90CE
#define GL_MAX_COMBINED_IMAGE_UNIFORMS    0x90CF
#define GL_COMPRESSED_RGBA_BPTC_UNORM     0x8E8C
#define GL_COMPRESSED_SRGB_ALPHA_BPTC_UNORM 0x8E8D
#define GL_COMPRESSED_RGB_BPTC_SIGNED_FLOAT 0x8E8E
#define GL_COMPRESSED_RGB_BPTC_UNSIGNED_FLOAT 0x8E8F
#define GL_TEXTURE_IMMUTABLE_FORMAT       0x912F
typedef void (APIENTRYP PFNGLDRAWARRAYSINSTANCEDBASEINSTANCEPROC) (GLenum mode, GLint first, GLsizei count, GLsizei instancecount, GLuint baseinstance);
typedef void (APIENTRYP PFNGLDRAWELEMENTSINSTANCEDBASEINSTANCEPROC) (GLenum mode, GLsizei count, GLenum type, const void *indices, GLsizei instancecount, GLuint baseinstance);
typedef void (APIENTRYP PFNGLDRAWELEMENTSINSTANCEDBASEVERTEXBASEINSTANCEPROC) (GLenum mode, GLsizei count, GLenum type, const void *indices, GLsizei instancecount, GLint basevertex, GLuint baseinstance);
typedef void (APIENTRYP PFNGLGETINTERNALFORMATIVPROC) (GLenum target, GLenum internalformat, GLenum pname, GLsizei bufSize, GLint *params);
typedef void (APIENTRYP PFNGLGETACTIVEATOMICCOUNTERBUFFERIVPROC) (GLuint program, GLuint bufferIndex, GLenum pname, GLint *params);
typedef void (APIENTRYP PFNGLBINDIMAGETEXTUREPROC) (GLuint unit, GLuint texture, GLint level, GLboolean layered, GLint layer, GLenum access, GLenum format);
typedef void (APIENTRYP PFNGLMEMORYBARRIERPROC) (GLbitfield barriers);
typedef void (APIENTRYP PFNGLTEXSTORAGE1DPROC) (GLenum target, GLsizei levels, GLenum internalformat, GLsizei width);
typedef void (APIENTRYP PFNGLTEXSTORAGE2DPROC) (GLenum target, GLsizei levels, GLenum internalformat, GLsizei width, GLsizei height);
typedef void (APIENTRYP PFNGLTEXSTORAGE3DPROC) (GLenum target, GLsizei levels, GLenum internalformat, GLsizei width, GLsizei height, GLsizei depth);
typedef void (APIENTRYP PFNGLDRAWTRANSFORMFEEDBACKINSTANCEDPROC) (GLenum mode, GLuint id, GLsizei instancecount);
typedef void (APIENTRYP PFNGLDRAWTRANSFORMFEEDBACKSTREAMINSTANCEDPROC) (GLenum mode, GLuint id, GLuint stream, GLsizei instancecount);

typedef void (APIENTRY  *GLDEBUGPROC)(GLenum source,GLenum type,GLuint id,GLenum severity,GLsizei length,const GLchar *message,const void *userParam);
#define GL_NUM_SHADING_LANGUAGE_VERSIONS  0x82E9
#define GL_VERTEX_ATTRIB_ARRAY_LONG       0x874E
#define GL_COMPRESSED_RGB8_ETC2           0x9274
#define GL_COMPRESSED_SRGB8_ETC2          0x9275
#define GL_COMPRESSED_RGB8_PUNCHTHROUGH_ALPHA1_ETC2 0x9276
#define GL_COMPRESSED_SRGB8_PUNCHTHROUGH_ALPHA1_ETC2 0x9277
#define GL_COMPRESSED_RGBA8_ETC2_EAC      0x9278
#define GL_COMPRESSED_SRGB8_ALPHA8_ETC2_EAC 0x9279
#define GL_COMPRESSED_R11_EAC             0x9270
#define GL_COMPRESSED_SIGNED_R11_EAC      0x9271
#define GL_COMPRESSED_RG11_EAC            0x9272
#define GL_COMPRESSED_SIGNED_RG11_EAC     0x9273
#define GL_PRIMITIVE_RESTART_FIXED_INDEX  0x8D69
#define GL_ANY_SAMPLES_PASSED_CONSERVATIVE 0x8D6A
#define GL_MAX_ELEMENT_INDEX              0x8D6B
#define GL_COMPUTE_SHADER                 0x91B9
#define GL_MAX_COMPUTE_UNIFORM_BLOCKS     0x91BB
#define GL_MAX_COMPUTE_TEXTURE_IMAGE_UNITS 0x91BC
#define GL_MAX_COMPUTE_IMAGE_UNIFORMS     0x91BD
#define GL_MAX_COMPUTE_SHARED_MEMORY_SIZE 0x8262
#define GL_MAX_COMPUTE_UNIFORM_COMPONENTS 0x8263
#define GL_MAX_COMPUTE_ATOMIC_COUNTER_BUFFERS 0x8264
#define GL_MAX_COMPUTE_ATOMIC_COUNTERS    0x8265
#define GL_MAX_COMBINED_COMPUTE_UNIFORM_COMPONENTS 0x8266
#define GL_MAX_COMPUTE_WORK_GROUP_INVOCATIONS 0x90EB
#define GL_MAX_COMPUTE_WORK_GROUP_COUNT   0x91BE
#define GL_MAX_COMPUTE_WORK_GROUP_SIZE    0x91BF
#define GL_COMPUTE_WORK_GROUP_SIZE        0x8267
#define GL_UNIFORM_BLOCK_REFERENCED_BY_COMPUTE_SHADER 0x90EC
#define GL_ATOMIC_COUNTER_BUFFER_REFERENCED_BY_COMPUTE_SHADER 0x90ED
#define GL_DISPATCH_INDIRECT_BUFFER       0x90EE
#define GL_DISPATCH_INDIRECT_BUFFER_BINDING 0x90EF
#define GL_DEBUG_OUTPUT_SYNCHRONOUS       0x8242
#define GL_DEBUG_NEXT_LOGGED_MESSAGE_LENGTH 0x8243
#define GL_DEBUG_CALLBACK_FUNCTION        0x8244
#define GL_DEBUG_CALLBACK_USER_PARAM      0x8245
#define GL_DEBUG_SOURCE_API               0x8246
#define GL_DEBUG_SOURCE_WINDOW_SYSTEM     0x8247
#define GL_DEBUG_SOURCE_SHADER_COMPILER   0x8248
#define GL_DEBUG_SOURCE_THIRD_PARTY       0x8249
#define GL_DEBUG_SOURCE_APPLICATION       0x824A
#define GL_DEBUG_SOURCE_OTHER             0x824B
#define GL_DEBUG_TYPE_ERROR               0x824C
#define GL_DEBUG_TYPE_DEPRECATED_BEHAVIOR 0x824D
#define GL_DEBUG_TYPE_UNDEFINED_BEHAVIOR  0x824E
#define GL_DEBUG_TYPE_PORTABILITY         0x824F
#define GL_DEBUG_TYPE_PERFORMANCE         0x8250
#define GL_DEBUG_TYPE_OTHER               0x8251
#define GL_MAX_DEBUG_MESSAGE_LENGTH       0x9143
#define GL_MAX_DEBUG_LOGGED_MESSAGES      0x9144
#define GL_DEBUG_LOGGED_MESSAGES          0x9145
#define GL_DEBUG_SEVERITY_HIGH            0x9146
#define GL_DEBUG_SEVERITY_MEDIUM          0x9147
#define GL_DEBUG_SEVERITY_LOW             0x9148
#define GL_DEBUG_TYPE_MARKER              0x8268
#define GL_DEBUG_TYPE_PUSH_GROUP          0x8269
#define GL_DEBUG_TYPE_POP_GROUP           0x826A
#define GL_DEBUG_SEVERITY_NOTIFICATION    0x826B
#define GL_MAX_DEBUG_GROUP_STACK_DEPTH    0x826C
#define GL_DEBUG_GROUP_STACK_DEPTH        0x826D
#define GL_BUFFER                         0x82E0
#define GL_SHADER                         0x82E1
#define GL_PROGRAM                        0x82E2
#define GL_QUERY                          0x82E3
#define GL_PROGRAM_PIPELINE               0x82E4
#define GL_SAMPLER                        0x82E6
#define GL_MAX_LABEL_LENGTH               0x82E8
#define GL_DEBUG_OUTPUT                   0x92E0
#define GL_CONTEXT_FLAG_DEBUG_BIT         0x00000002
#define GL_MAX_UNIFORM_LOCATIONS          0x826E
#define GL_FRAMEBUFFER_DEFAULT_WIDTH      0x9310
#define GL_FRAMEBUFFER_DEFAULT_HEIGHT     0x9311
#define GL_FRAMEBUFFER_DEFAULT_LAYERS     0x9312
#define GL_FRAMEBUFFER_DEFAULT_SAMPLES    0x9313
#define GL_FRAMEBUFFER_DEFAULT_FIXED_SAMPLE_LOCATIONS 0x9314
#define GL_MAX_FRAMEBUFFER_WIDTH          0x9315
#define GL_MAX_FRAMEBUFFER_HEIGHT         0x9316
#define GL_MAX_FRAMEBUFFER_LAYERS         0x9317
#define GL_MAX_FRAMEBUFFER_SAMPLES        0x9318
#define GL_INTERNALFORMAT_SUPPORTED       0x826F
#define GL_INTERNALFORMAT_PREFERRED       0x8270
#define GL_INTERNALFORMAT_RED_SIZE        0x8271
#define GL_INTERNALFORMAT_GREEN_SIZE      0x8272
#define GL_INTERNALFORMAT_BLUE_SIZE       0x8273
#define GL_INTERNALFORMAT_ALPHA_SIZE      0x8274
#define GL_INTERNALFORMAT_DEPTH_SIZE      0x8275
#define GL_INTERNALFORMAT_STENCIL_SIZE    0x8276
#define GL_INTERNALFORMAT_SHARED_SIZE     0x8277
#define GL_INTERNALFORMAT_RED_TYPE        0x8278
#define GL_INTERNALFORMAT_GREEN_TYPE      0x8279
#define GL_INTERNALFORMAT_BLUE_TYPE       0x827A
#define GL_INTERNALFORMAT_ALPHA_TYPE      0x827B
#define GL_INTERNALFORMAT_DEPTH_TYPE      0x827C
#define GL_INTERNALFORMAT_STENCIL_TYPE    0x827D
#define GL_MAX_WIDTH                      0x827E
#define GL_MAX_HEIGHT                     0x827F
#define GL_MAX_DEPTH                      0x8280
#define GL_MAX_LAYERS                     0x8281
#define GL_MAX_COMBINED_DIMENSIONS        0x8282
#define GL_COLOR_COMPONENTS               0x8283
#define GL_DEPTH_COMPONENTS               0x8284
#define GL_STENCIL_COMPONENTS             0x8285
#define GL_COLOR_RENDERABLE               0x8286
#define GL_DEPTH_RENDERABLE               0x8287
#define GL_STENCIL_RENDERABLE             0x8288
#define GL_FRAMEBUFFER_RENDERABLE         0x8289
#define GL_FRAMEBUFFER_RENDERABLE_LAYERED 0x828A
#define GL_FRAMEBUFFER_BLEND              0x828B
#define GL_READ_PIXELS                    0x828C
#define GL_READ_PIXELS_FORMAT             0x828D
#define GL_READ_PIXELS_TYPE               0x828E
#define GL_TEXTURE_IMAGE_FORMAT           0x828F
#define GL_TEXTURE_IMAGE_TYPE             0x8290
#define GL_GET_TEXTURE_IMAGE_FORMAT       0x8291
#define GL_GET_TEXTURE_IMAGE_TYPE         0x8292
#define GL_MIPMAP                         0x8293
#define GL_MANUAL_GENERATE_MIPMAP         0x8294
#define GL_AUTO_GENERATE_MIPMAP           0x8295
#define GL_COLOR_ENCODING                 0x8296
#define GL_SRGB_READ                      0x8297
#define GL_SRGB_WRITE                     0x8298
#define GL_FILTER                         0x829A
#define GL_VERTEX_TEXTURE                 0x829B
#define GL_TESS_CONTROL_TEXTURE           0x829C
#define GL_TESS_EVALUATION_TEXTURE        0x829D
#define GL_GEOMETRY_TEXTURE               0x829E
#define GL_FRAGMENT_TEXTURE               0x829F
#define GL_COMPUTE_TEXTURE                0x82A0
#define GL_TEXTURE_SHADOW                 0x82A1
#define GL_TEXTURE_GATHER                 0x82A2
#define GL_TEXTURE_GATHER_SHADOW          0x82A3
#define GL_SHADER_IMAGE_LOAD              0x82A4
#define GL_SHADER_IMAGE_STORE             0x82A5
#define GL_SHADER_IMAGE_ATOMIC            0x82A6
#define GL_IMAGE_TEXEL_SIZE               0x82A7
#define GL_IMAGE_COMPATIBILITY_CLASS      0x82A8
#define GL_IMAGE_PIXEL_FORMAT             0x82A9
#define GL_IMAGE_PIXEL_TYPE               0x82AA
#define GL_SIMULTANEOUS_TEXTURE_AND_DEPTH_TEST 0x82AC
#define GL_SIMULTANEOUS_TEXTURE_AND_STENCIL_TEST 0x82AD
#define GL_SIMULTANEOUS_TEXTURE_AND_DEPTH_WRITE 0x82AE
#define GL_SIMULTANEOUS_TEXTURE_AND_STENCIL_WRITE 0x82AF
#define GL_TEXTURE_COMPRESSED_BLOCK_WIDTH 0x82B1
#define GL_TEXTURE_COMPRESSED_BLOCK_HEIGHT 0x82B2
#define GL_TEXTURE_COMPRESSED_BLOCK_SIZE  0x82B3
#define GL_CLEAR_BUFFER                   0x82B4
#define GL_TEXTURE_VIEW                   0x82B5
#define GL_VIEW_COMPATIBILITY_CLASS       0x82B6
#define GL_FULL_SUPPORT                   0x82B7
#define GL_CAVEAT_SUPPORT                 0x82B8
#define GL_IMAGE_CLASS_4_X_32             0x82B9
#define GL_IMAGE_CLASS_2_X_32             0x82BA
#define GL_IMAGE_CLASS_1_X_32             0x82BB
#define GL_IMAGE_CLASS_4_X_16             0x82BC
#define GL_IMAGE_CLASS_2_X_16             0x82BD
#define GL_IMAGE_CLASS_1_X_16             0x82BE
#define GL_IMAGE_CLASS_4_X_8              0x82BF
#define GL_IMAGE_CLASS_2_X_8              0x82C0
#define GL_IMAGE_CLASS_1_X_8              0x82C1
#define GL_IMAGE_CLASS_11_11_10           0x82C2
#define GL_IMAGE_CLASS_10_10_10_2         0x82C3
#define GL_VIEW_CLASS_128_BITS            0x82C4
#define GL_VIEW_CLASS_96_BITS             0x82C5
#define GL_VIEW_CLASS_64_BITS             0x82C6
#define GL_VIEW_CLASS_48_BITS             0x82C7
#define GL_VIEW_CLASS_32_BITS             0x82C8
#define GL_VIEW_CLASS_24_BITS             0x82C9
#define GL_VIEW_CLASS_16_BITS             0x82CA
#define GL_VIEW_CLASS_8_BITS              0x82CB
#define GL_VIEW_CLASS_S3TC_DXT1_RGB       0x82CC
#define GL_VIEW_CLASS_S3TC_DXT1_RGBA      0x82CD
#define GL_VIEW_CLASS_S3TC_DXT3_RGBA      0x82CE
#define GL_VIEW_CLASS_S3TC_DXT5_RGBA      0x82CF
#define GL_VIEW_CLASS_RGTC1_RED           0x82D0
#define GL_VIEW_CLASS_RGTC2_RG            0x82D1
#define GL_VIEW_CLASS_BPTC_UNORM          0x82D2
#define GL_VIEW_CLASS_BPTC_FLOAT          0x82D3
#define GL_UNIFORM                        0x92E1
#define GL_UNIFORM_BLOCK                  0x92E2
#define GL_PROGRAM_INPUT                  0x92E3
#define GL_PROGRAM_OUTPUT                 0x92E4
#define GL_BUFFER_VARIABLE                0x92E5
#define GL_SHADER_STORAGE_BLOCK           0x92E6
#define GL_VERTEX_SUBROUTINE              0x92E8
#define GL_TESS_CONTROL_SUBROUTINE        0x92E9
#define GL_TESS_EVALUATION_SUBROUTINE     0x92EA
#define GL_GEOMETRY_SUBROUTINE            0x92EB
#define GL_FRAGMENT_SUBROUTINE            0x92EC
#define GL_COMPUTE_SUBROUTINE             0x92ED
#define GL_VERTEX_SUBROUTINE_UNIFORM      0x92EE
#define GL_TESS_CONTROL_SUBROUTINE_UNIFORM 0x92EF
#define GL_TESS_EVALUATION_SUBROUTINE_UNIFORM 0x92F0
#define GL_GEOMETRY_SUBROUTINE_UNIFORM    0x92F1
#define GL_FRAGMENT_SUBROUTINE_UNIFORM    0x92F2
#define GL_COMPUTE_SUBROUTINE_UNIFORM     0x92F3
#define GL_TRANSFORM_FEEDBACK_VARYING     0x92F4
#define GL_ACTIVE_RESOURCES               0x92F5
#define GL_MAX_NAME_LENGTH                0x92F6
#define GL_MAX_NUM_ACTIVE_VARIABLES       0x92F7
#define GL_MAX_NUM_COMPATIBLE_SUBROUTINES 0x92F8
#define GL_NAME_LENGTH                    0x92F9
#define GL_TYPE                           0x92FA
#define GL_ARRAY_SIZE                     0x92FB
#define GL_OFFSET                         0x92FC
#define GL_BLOCK_INDEX                    0x92FD
#define GL_ARRAY_STRIDE                   0x92FE
#define GL_MATRIX_STRIDE                  0x92FF
#define GL_IS_ROW_MAJOR                   0x9300
#define GL_ATOMIC_COUNTER_BUFFER_INDEX    0x9301
#define GL_BUFFER_BINDING                 0x9302
#define GL_BUFFER_DATA_SIZE               0x9303
#define GL_NUM_ACTIVE_VARIABLES           0x9304
#define GL_ACTIVE_VARIABLES               0x9305
#define GL_REFERENCED_BY_VERTEX_SHADER    0x9306
#define GL_REFERENCED_BY_TESS_CONTROL_SHADER 0x9307
#define GL_REFERENCED_BY_TESS_EVALUATION_SHADER 0x9308
#define GL_REFERENCED_BY_GEOMETRY_SHADER  0x9309
#define GL_REFERENCED_BY_FRAGMENT_SHADER  0x930A
#define GL_REFERENCED_BY_COMPUTE_SHADER   0x930B
#define GL_TOP_LEVEL_ARRAY_SIZE           0x930C
#define GL_TOP_LEVEL_ARRAY_STRIDE         0x930D
#define GL_LOCATION                       0x930E
#define GL_LOCATION_INDEX                 0x930F
#define GL_IS_PER_PATCH                   0x92E7
#define GL_SHADER_STORAGE_BUFFER          0x90D2
#define GL_SHADER_STORAGE_BUFFER_BINDING  0x90D3
#define GL_SHADER_STORAGE_BUFFER_START    0x90D4
#define GL_SHADER_STORAGE_BUFFER_SIZE     0x90D5
#define GL_MAX_VERTEX_SHADER_STORAGE_BLOCKS 0x90D6
#define GL_MAX_GEOMETRY_SHADER_STORAGE_BLOCKS 0x90D7
#define GL_MAX_TESS_CONTROL_SHADER_STORAGE_BLOCKS 0x90D8
#define GL_MAX_TESS_EVALUATION_SHADER_STORAGE_BLOCKS 0x90D9
#define GL_MAX_FRAGMENT_SHADER_STORAGE_BLOCKS 0x90DA
#define GL_MAX_COMPUTE_SHADER_STORAGE_BLOCKS 0x90DB
#define GL_MAX_COMBINED_SHADER_STORAGE_BLOCKS 0x90DC
#define GL_MAX_SHADER_STORAGE_BUFFER_BINDINGS 0x90DD
#define GL_MAX_SHADER_STORAGE_BLOCK_SIZE  0x90DE
#define GL_SHADER_STORAGE_BUFFER_OFFSET_ALIGNMENT 0x90DF
#define GL_SHADER_STORAGE_BARRIER_BIT     0x00002000
#define GL_MAX_COMBINED_SHADER_OUTPUT_RESOURCES 0x8F39
#define GL_DEPTH_STENCIL_TEXTURE_MODE     0x90EA
#define GL_TEXTURE_BUFFER_OFFSET          0x919D
#define GL_TEXTURE_BUFFER_SIZE            0x919E
#define GL_TEXTURE_BUFFER_OFFSET_ALIGNMENT 0x919F
#define GL_TEXTURE_VIEW_MIN_LEVEL         0x82DB
#define GL_TEXTURE_VIEW_NUM_LEVELS        0x82DC
#define GL_TEXTURE_VIEW_MIN_LAYER         0x82DD
#define GL_TEXTURE_VIEW_NUM_LAYERS        0x82DE
#define GL_TEXTURE_IMMUTABLE_LEVELS       0x82DF
#define GL_VERTEX_ATTRIB_BINDING          0x82D4
#define GL_VERTEX_ATTRIB_RELATIVE_OFFSET  0x82D5
#define GL_VERTEX_BINDING_DIVISOR         0x82D6
#define GL_VERTEX_BINDING_OFFSET          0x82D7
#define GL_VERTEX_BINDING_STRIDE          0x82D8
#define GL_MAX_VERTEX_ATTRIB_RELATIVE_OFFSET 0x82D9
#define GL_MAX_VERTEX_ATTRIB_BINDINGS     0x82DA
#define GL_VERTEX_BINDING_BUFFER          0x8F4F
typedef void (APIENTRYP PFNGLCLEARBUFFERDATAPROC) (GLenum target, GLenum internalformat, GLenum format, GLenum type, const void *data);
typedef void (APIENTRYP PFNGLCLEARBUFFERSUBDATAPROC) (GLenum target, GLenum internalformat, GLintptr offset, GLsizeiptr size, GLenum format, GLenum type, const void *data);
typedef void (APIENTRYP PFNGLDISPATCHCOMPUTEPROC) (GLuint num_groups_x, GLuint num_groups_y, GLuint num_groups_z);
typedef void (APIENTRYP PFNGLDISPATCHCOMPUTEINDIRECTPROC) (GLintptr indirect);
typedef void (APIENTRYP PFNGLCOPYIMAGESUBDATAPROC) (GLuint srcName, GLenum srcTarget, GLint srcLevel, GLint srcX, GLint srcY, GLint srcZ, GLuint dstName, GLenum dstTarget, GLint dstLevel, GLint dstX, GLint dstY, GLint dstZ, GLsizei srcWidth, GLsizei srcHeight, GLsizei srcDepth);
typedef void (APIENTRYP PFNGLFRAMEBUFFERPARAMETERIPROC) (GLenum target, GLenum pname, GLint param);
typedef void (APIENTRYP PFNGLGETFRAMEBUFFERPARAMETERIVPROC) (GLenum target, GLenum pname, GLint *params);
typedef void (APIENTRYP PFNGLGETINTERNALFORMATI64VPROC) (GLenum target, GLenum internalformat, GLenum pname, GLsizei bufSize, GLint64 *params);
typedef void (APIENTRYP PFNGLINVALIDATETEXSUBIMAGEPROC) (GLuint texture, GLint level, GLint xoffset, GLint yoffset, GLint zoffset, GLsizei width, GLsizei height, GLsizei depth);
typedef void (APIENTRYP PFNGLINVALIDATETEXIMAGEPROC) (GLuint texture, GLint level);
typedef void (APIENTRYP PFNGLINVALIDATEBUFFERSUBDATAPROC) (GLuint buffer, GLintptr offset, GLsizeiptr length);
typedef void (APIENTRYP PFNGLINVALIDATEBUFFERDATAPROC) (GLuint buffer);
typedef void (APIENTRYP PFNGLINVALIDATEFRAMEBUFFERPROC) (GLenum target, GLsizei numAttachments, const GLenum *attachments);
typedef void (APIENTRYP PFNGLINVALIDATESUBFRAMEBUFFERPROC) (GLenum target, GLsizei numAttachments, const GLenum *attachments, GLint x, GLint y, GLsizei width, GLsizei height);
typedef void (APIENTRYP PFNGLMULTIDRAWARRAYSINDIRECTPROC) (GLenum mode, const void *indirect, GLsizei drawcount, GLsizei stride);
typedef void (APIENTRYP PFNGLMULTIDRAWELEMENTSINDIRECTPROC) (GLenum mode, GLenum type, const void *indirect, GLsizei drawcount, GLsizei stride);
typedef void (APIENTRYP PFNGLGETPROGRAMINTERFACEIVPROC) (GLuint program, GLenum programInterface, GLenum pname, GLint *params);
typedef GLuint (APIENTRYP PFNGLGETPROGRAMRESOURCEINDEXPROC) (GLuint program, GLenum programInterface, const GLchar *name);
typedef void (APIENTRYP PFNGLGETPROGRAMRESOURCENAMEPROC) (GLuint program, GLenum programInterface, GLuint index, GLsizei bufSize, GLsizei *length, GLchar *name);
typedef void (APIENTRYP PFNGLGETPROGRAMRESOURCEIVPROC) (GLuint program, GLenum programInterface, GLuint index, GLsizei propCount, const GLenum *props, GLsizei bufSize, GLsizei *length, GLint *params);
typedef GLint (APIENTRYP PFNGLGETPROGRAMRESOURCELOCATIONPROC) (GLuint program, GLenum programInterface, const GLchar *name);
typedef GLint (APIENTRYP PFNGLGETPROGRAMRESOURCELOCATIONINDEXPROC) (GLuint program, GLenum programInterface, const GLchar *name);
typedef void (APIENTRYP PFNGLSHADERSTORAGEBLOCKBINDINGPROC) (GLuint program, GLuint storageBlockIndex, GLuint storageBlockBinding);
typedef void (APIENTRYP PFNGLTEXBUFFERRANGEPROC) (GLenum target, GLenum internalformat, GLuint buffer, GLintptr offset, GLsizeiptr size);
typedef void (APIENTRYP PFNGLTEXSTORAGE2DMULTISAMPLEPROC) (GLenum target, GLsizei samples, GLenum internalformat, GLsizei width, GLsizei height, GLboolean fixedsamplelocations);
typedef void (APIENTRYP PFNGLTEXSTORAGE3DMULTISAMPLEPROC) (GLenum target, GLsizei samples, GLenum internalformat, GLsizei width, GLsizei height, GLsizei depth, GLboolean fixedsamplelocations);
typedef void (APIENTRYP PFNGLTEXTUREVIEWPROC) (GLuint texture, GLenum target, GLuint origtexture, GLenum internalformat, GLuint minlevel, GLuint numlevels, GLuint minlayer, GLuint numlayers);
typedef void (APIENTRYP PFNGLBINDVERTEXBUFFERPROC) (GLuint bindingindex, GLuint buffer, GLintptr offset, GLsizei stride);
typedef void (APIENTRYP PFNGLVERTEXATTRIBFORMATPROC) (GLuint attribindex, GLint size, GLenum type, GLboolean normalized, GLuint relativeoffset);
typedef void (APIENTRYP PFNGLVERTEXATTRIBIFORMATPROC) (GLuint attribindex, GLint size, GLenum type, GLuint relativeoffset);
typedef void (APIENTRYP PFNGLVERTEXATTRIBLFORMATPROC) (GLuint attribindex, GLint size, GLenum type, GLuint relativeoffset);
typedef void (APIENTRYP PFNGLVERTEXATTRIBBINDINGPROC) (GLuint attribindex, GLuint bindingindex);
typedef void (APIENTRYP PFNGLVERTEXBINDINGDIVISORPROC) (GLuint bindingindex, GLuint divisor);
typedef void (APIENTRYP PFNGLDEBUGMESSAGECONTROLPROC) (GLenum source, GLenum type, GLenum severity, GLsizei count, const GLuint *ids, GLboolean enabled);
typedef void (APIENTRYP PFNGLDEBUGMESSAGEINSERTPROC) (GLenum source, GLenum type, GLuint id, GLenum severity, GLsizei length, const GLchar *buf);
typedef void (APIENTRYP PFNGLDEBUGMESSAGECALLBACKPROC) (GLDEBUGPROC callback, const void *userParam);
typedef GLuint (APIENTRYP PFNGLGETDEBUGMESSAGELOGPROC) (GLuint count, GLsizei bufSize, GLenum *sources, GLenum *types, GLuint *ids, GLenum *severities, GLsizei *lengths, GLchar *messageLog);
typedef void (APIENTRYP PFNGLPUSHDEBUGGROUPPROC) (GLenum source, GLuint id, GLsizei length, const GLchar *message);
typedef void (APIENTRYP PFNGLPOPDEBUGGROUPPROC) (void);
typedef void (APIENTRYP PFNGLOBJECTLABELPROC) (GLenum identifier, GLuint name, GLsizei length, const GLchar *label);
typedef void (APIENTRYP PFNGLGETOBJECTLABELPROC) (GLenum identifier, GLuint name, GLsizei bufSize, GLsizei *length, GLchar *label);
typedef void (APIENTRYP PFNGLOBJECTPTRLABELPROC) (const void *ptr, GLsizei length, const GLchar *label);
typedef void (APIENTRYP PFNGLGETOBJECTPTRLABELPROC) (const void *ptr, GLsizei bufSize, GLsizei *length, GLchar *label);

#define GL_MAX_VERTEX_ATTRIB_STRIDE       0x82E5
#define GL_PRIMITIVE_RESTART_FOR_PATCHES_SUPPORTED 0x8221
#define GL_TEXTURE_BUFFER_BINDING         0x8C2A
#define GL_MAP_PERSISTENT_BIT             0x0040
#define GL_MAP_COHERENT_BIT               0x0080
#define GL_DYNAMIC_STORAGE_BIT            0x0100
#define GL_CLIENT_STORAGE_BIT             0x0200
#define GL_CLIENT_MAPPED_BUFFER_BARRIER_BIT 0x00004000
#define GL_BUFFER_IMMUTABLE_STORAGE       0x821F
#define GL_BUFFER_STORAGE_FLAGS           0x8220
#define GL_CLEAR_TEXTURE                  0x9365
#define GL_LOCATION_COMPONENT             0x934A
#define GL_TRANSFORM_FEEDBACK_BUFFER_INDEX 0x934B
#define GL_TRANSFORM_FEEDBACK_BUFFER_STRIDE 0x934C
#define GL_QUERY_BUFFER                   0x9192
#define GL_QUERY_BUFFER_BARRIER_BIT       0x00008000
#define GL_QUERY_BUFFER_BINDING           0x9193
#define GL_QUERY_RESULT_NO_WAIT           0x9194
#define GL_MIRROR_CLAMP_TO_EDGE           0x8743
typedef void (APIENTRYP PFNGLBUFFERSTORAGEPROC) (GLenum target, GLsizeiptr size, const void *data, GLbitfield flags);
typedef void (APIENTRYP PFNGLCLEARTEXIMAGEPROC) (GLuint texture, GLint level, GLenum format, GLenum type, const void *data);
typedef void (APIENTRYP PFNGLCLEARTEXSUBIMAGEPROC) (GLuint texture, GLint level, GLint xoffset, GLint yoffset, GLint zoffset, GLsizei width, GLsizei height, GLsizei depth, GLenum format, GLenum type, const void *data);
typedef void (APIENTRYP PFNGLBINDBUFFERSBASEPROC) (GLenum target, GLuint first, GLsizei count, const GLuint *buffers);
typedef void (APIENTRYP PFNGLBINDBUFFERSRANGEPROC) (GLenum target, GLuint first, GLsizei count, const GLuint *buffers, const GLintptr *offsets, const GLsizeiptr *sizes);
typedef void (APIENTRYP PFNGLBINDTEXTURESPROC) (GLuint first, GLsizei count, const GLuint *textures);
typedef void (APIENTRYP PFNGLBINDSAMPLERSPROC) (GLuint first, GLsizei count, const GLuint *samplers);
typedef void (APIENTRYP PFNGLBINDIMAGETEXTURESPROC) (GLuint first, GLsizei count, const GLuint *textures);
typedef void (APIENTRYP PFNGLBINDVERTEXBUFFERSPROC) (GLuint first, GLsizei count, const GLuint *buffers, const GLintptr *offsets, const GLsizei *strides);

typedef uint64_t GLuint64EXT;
#define GL_UNSIGNED_INT64_ARB             0x140F
typedef GLuint64 (APIENTRYP PFNGLGETTEXTUREHANDLEARBPROC) (GLuint texture);
typedef GLuint64 (APIENTRYP PFNGLGETTEXTURESAMPLERHANDLEARBPROC) (GLuint texture, GLuint sampler);
typedef void (APIENTRYP PFNGLMAKETEXTUREHANDLERESIDENTARBPROC) (GLuint64 handle);
typedef void (APIENTRYP PFNGLMAKETEXTUREHANDLENONRESIDENTARBPROC) (GLuint64 handle);
typedef GLuint64 (APIENTRYP PFNGLGETIMAGEHANDLEARBPROC) (GLuint texture, GLint level, GLboolean layered, GLint layer, GLenum format);
typedef void (APIENTRYP PFNGLMAKEIMAGEHANDLERESIDENTARBPROC) (GLuint64 handle, GLenum access);
typedef void (APIENTRYP PFNGLMAKEIMAGEHANDLENONRESIDENTARBPROC) (GLuint64 handle);
typedef void (APIENTRYP PFNGLUNIFORMHANDLEUI64ARBPROC) (GLint location, GLuint64 value);
typedef void (APIENTRYP PFNGLUNIFORMHANDLEUI64VARBPROC) (GLint location, GLsizei count, const GLuint64 *value);
typedef void (APIENTRYP PFNGLPROGRAMUNIFORMHANDLEUI64ARBPROC) (GLuint program, GLint location, GLuint64 value);
typedef void (APIENTRYP PFNGLPROGRAMUNIFORMHANDLEUI64VARBPROC) (GLuint program, GLint location, GLsizei count, const GLuint64 *values);
typedef GLboolean (APIENTRYP PFNGLISTEXTUREHANDLERESIDENTARBPROC) (GLuint64 handle);
typedef GLboolean (APIENTRYP PFNGLISIMAGEHANDLERESIDENTARBPROC) (GLuint64 handle);
typedef void (APIENTRYP PFNGLVERTEXATTRIBL1UI64ARBPROC) (GLuint index, GLuint64EXT x);
typedef void (APIENTRYP PFNGLVERTEXATTRIBL1UI64VARBPROC) (GLuint index, const GLuint64EXT *v);
typedef void (APIENTRYP PFNGLGETVERTEXATTRIBLUI64VARBPROC) (GLuint index, GLenum pname, GLuint64EXT *params);

struct _cl_context;
struct _cl_event;
#define GL_SYNC_CL_EVENT_ARB              0x8240
#define GL_SYNC_CL_EVENT_COMPLETE_ARB     0x8241
typedef GLsync (APIENTRYP PFNGLCREATESYNCFROMCLEVENTARBPROC) (struct _cl_context *context, struct _cl_event *event, GLbitfield flags);

#define GL_COMPUTE_SHADER_BIT             0x00000020

#define GL_MAX_COMPUTE_VARIABLE_GROUP_INVOCATIONS_ARB 0x9344
#define GL_MAX_COMPUTE_FIXED_GROUP_INVOCATIONS_ARB 0x90EB
#define GL_MAX_COMPUTE_VARIABLE_GROUP_SIZE_ARB 0x9345
#define GL_MAX_COMPUTE_FIXED_GROUP_SIZE_ARB 0x91BF
typedef void (APIENTRYP PFNGLDISPATCHCOMPUTEGROUPSIZEARBPROC) (GLuint num_groups_x, GLuint num_groups_y, GLuint num_groups_z, GLuint group_size_x, GLuint group_size_y, GLuint group_size_z);

#define GL_COPY_READ_BUFFER_BINDING       0x8F36
#define GL_COPY_WRITE_BUFFER_BINDING      0x8F37

typedef void (APIENTRY  *GLDEBUGPROCARB)(GLenum source,GLenum type,GLuint id,GLenum severity,GLsizei length,const GLchar *message,const void *userParam);
#define GL_DEBUG_OUTPUT_SYNCHRONOUS_ARB   0x8242
#define GL_DEBUG_NEXT_LOGGED_MESSAGE_LENGTH_ARB 0x8243
#define GL_DEBUG_CALLBACK_FUNCTION_ARB    0x8244
#define GL_DEBUG_CALLBACK_USER_PARAM_ARB  0x8245
#define GL_DEBUG_SOURCE_API_ARB           0x8246
#define GL_DEBUG_SOURCE_WINDOW_SYSTEM_ARB 0x8247
#define GL_DEBUG_SOURCE_SHADER_COMPILER_ARB 0x8248
#define GL_DEBUG_SOURCE_THIRD_PARTY_ARB   0x8249
#define GL_DEBUG_SOURCE_APPLICATION_ARB   0x824A
#define GL_DEBUG_SOURCE_OTHER_ARB         0x824B
#define GL_DEBUG_TYPE_ERROR_ARB           0x824C
#define GL_DEBUG_TYPE_DEPRECATED_BEHAVIOR_ARB 0x824D
#define GL_DEBUG_TYPE_UNDEFINED_BEHAVIOR_ARB 0x824E
#define GL_DEBUG_TYPE_PORTABILITY_ARB     0x824F
#define GL_DEBUG_TYPE_PERFORMANCE_ARB     0x8250
#define GL_DEBUG_TYPE_OTHER_ARB           0x8251
#define GL_MAX_DEBUG_MESSAGE_LENGTH_ARB   0x9143
#define GL_MAX_DEBUG_LOGGED_MESSAGES_ARB  0x9144
#define GL_DEBUG_LOGGED_MESSAGES_ARB      0x9145
#define GL_DEBUG_SEVERITY_HIGH_ARB        0x9146
#define GL_DEBUG_SEVERITY_MEDIUM_ARB      0x9147
#define GL_DEBUG_SEVERITY_LOW_ARB         0x9148
typedef void (APIENTRYP PFNGLDEBUGMESSAGECONTROLARBPROC) (GLenum source, GLenum type, GLenum severity, GLsizei count, const GLuint *ids, GLboolean enabled);
typedef void (APIENTRYP PFNGLDEBUGMESSAGEINSERTARBPROC) (GLenum source, GLenum type, GLuint id, GLenum severity, GLsizei length, const GLchar *buf);
typedef void (APIENTRYP PFNGLDEBUGMESSAGECALLBACKARBPROC) (GLDEBUGPROCARB callback, const void *userParam);
typedef GLuint (APIENTRYP PFNGLGETDEBUGMESSAGELOGARBPROC) (GLuint count, GLsizei bufSize, GLenum *sources, GLenum *types, GLuint *ids, GLenum *severities, GLsizei *lengths, GLchar *messageLog);

typedef void (APIENTRYP PFNGLBLENDEQUATIONIARBPROC) (GLuint buf, GLenum mode);
typedef void (APIENTRYP PFNGLBLENDEQUATIONSEPARATEIARBPROC) (GLuint buf, GLenum modeRGB, GLenum modeAlpha);
typedef void (APIENTRYP PFNGLBLENDFUNCIARBPROC) (GLuint buf, GLenum src, GLenum dst);
typedef void (APIENTRYP PFNGLBLENDFUNCSEPARATEIARBPROC) (GLuint buf, GLenum srcRGB, GLenum dstRGB, GLenum srcAlpha, GLenum dstAlpha);

#define GL_BLEND_COLOR                    0x8005
#define GL_BLEND_EQUATION                 0x8009

#define GL_PARAMETER_BUFFER_ARB           0x80EE
#define GL_PARAMETER_BUFFER_BINDING_ARB   0x80EF
typedef void (APIENTRYP PFNGLMULTIDRAWARRAYSINDIRECTCOUNTARBPROC) (GLenum mode, GLintptr indirect, GLintptr drawcount, GLsizei maxdrawcount, GLsizei stride);
typedef void (APIENTRYP PFNGLMULTIDRAWELEMENTSINDIRECTCOUNTARBPROC) (GLenum mode, GLenum type, GLintptr indirect, GLintptr drawcount, GLsizei maxdrawcount, GLsizei stride);

#define GL_SRGB_DECODE_ARB                0x8299

#define GL_CONTEXT_FLAG_ROBUST_ACCESS_BIT_ARB 0x00000004
#define GL_LOSE_CONTEXT_ON_RESET_ARB      0x8252
#define GL_GUILTY_CONTEXT_RESET_ARB       0x8253
#define GL_INNOCENT_CONTEXT_RESET_ARB     0x8254
#define GL_UNKNOWN_CONTEXT_RESET_ARB      0x8255
#define GL_RESET_NOTIFICATION_STRATEGY_ARB 0x8256
#define GL_NO_RESET_NOTIFICATION_ARB      0x8261
typedef GLenum (APIENTRYP PFNGLGETGRAPHICSRESETSTATUSARBPROC) (void);
typedef void (APIENTRYP PFNGLGETNTEXIMAGEARBPROC) (GLenum target, GLint level, GLenum format, GLenum type, GLsizei bufSize, void *img);
typedef void (APIENTRYP PFNGLREADNPIXELSARBPROC) (GLint x, GLint y, GLsizei width, GLsizei height, GLenum format, GLenum type, GLsizei bufSize, void *data);
typedef void (APIENTRYP PFNGLGETNCOMPRESSEDTEXIMAGEARBPROC) (GLenum target, GLint lod, GLsizei bufSize, void *img);
typedef void (APIENTRYP PFNGLGETNUNIFORMFVARBPROC) (GLuint program, GLint location, GLsizei bufSize, GLfloat *params);
typedef void (APIENTRYP PFNGLGETNUNIFORMIVARBPROC) (GLuint program, GLint location, GLsizei bufSize, GLint *params);
typedef void (APIENTRYP PFNGLGETNUNIFORMUIVARBPROC) (GLuint program, GLint location, GLsizei bufSize, GLuint *params);
typedef void (APIENTRYP PFNGLGETNUNIFORMDVARBPROC) (GLuint program, GLint location, GLsizei bufSize, GLdouble *params);

#define GL_SAMPLE_SHADING_ARB             0x8C36
#define GL_MIN_SAMPLE_SHADING_VALUE_ARB   0x8C37
typedef void (APIENTRYP PFNGLMINSAMPLESHADINGARBPROC) (GLfloat value);

#define GL_SHADER_INCLUDE_ARB             0x8DAE
#define GL_NAMED_STRING_LENGTH_ARB        0x8DE9
#define GL_NAMED_STRING_TYPE_ARB          0x8DEA
typedef void (APIENTRYP PFNGLNAMEDSTRINGARBPROC) (GLenum type, GLint namelen, const GLchar *name, GLint stringlen, const GLchar *string);
typedef void (APIENTRYP PFNGLDELETENAMEDSTRINGARBPROC) (GLint namelen, const GLchar *name);
typedef void (APIENTRYP PFNGLCOMPILESHADERINCLUDEARBPROC) (GLuint shader, GLsizei count, const GLchar *const*path, const GLint *length);
typedef GLboolean (APIENTRYP PFNGLISNAMEDSTRINGARBPROC) (GLint namelen, const GLchar *name);
typedef void (APIENTRYP PFNGLGETNAMEDSTRINGARBPROC) (GLint namelen, const GLchar *name, GLsizei bufSize, GLint *stringlen, GLchar *string);
typedef void (APIENTRYP PFNGLGETNAMEDSTRINGIVARBPROC) (GLint namelen, const GLchar *name, GLenum pname, GLint *params);

#define GL_TEXTURE_SPARSE_ARB             0x91A6
#define GL_VIRTUAL_PAGE_SIZE_INDEX_ARB    0x91A7
#define GL_MIN_SPARSE_LEVEL_ARB           0x919B
#define GL_NUM_VIRTUAL_PAGE_SIZES_ARB     0x91A8
#define GL_VIRTUAL_PAGE_SIZE_X_ARB        0x9195
#define GL_VIRTUAL_PAGE_SIZE_Y_ARB        0x9196
#define GL_VIRTUAL_PAGE_SIZE_Z_ARB        0x9197
#define GL_MAX_SPARSE_TEXTURE_SIZE_ARB    0x9198
#define GL_MAX_SPARSE_3D_TEXTURE_SIZE_ARB 0x9199
#define GL_MAX_SPARSE_ARRAY_TEXTURE_LAYERS_ARB 0x919A
#define GL_SPARSE_TEXTURE_FULL_ARRAY_CUBE_MIPMAPS_ARB 0x91A9
typedef void (APIENTRYP PFNGLTEXPAGECOMMITMENTARBPROC) (GLenum target, GLint level, GLint xoffset, GLint yoffset, GLint zoffset, GLsizei width, GLsizei height, GLsizei depth, GLboolean resident);

#define GL_COMPRESSED_RGBA_BPTC_UNORM_ARB 0x8E8C
#define GL_COMPRESSED_SRGB_ALPHA_BPTC_UNORM_ARB 0x8E8D
#define GL_COMPRESSED_RGB_BPTC_SIGNED_FLOAT_ARB 0x8E8E
#define GL_COMPRESSED_RGB_BPTC_UNSIGNED_FLOAT_ARB 0x8E8F

#define GL_TEXTURE_CUBE_MAP_ARRAY_ARB     0x9009
#define GL_TEXTURE_BINDING_CUBE_MAP_ARRAY_ARB 0x900A
#define GL_PROXY_TEXTURE_CUBE_MAP_ARRAY_ARB 0x900B
#define GL_SAMPLER_CUBE_MAP_ARRAY_ARB     0x900C
#define GL_SAMPLER_CUBE_MAP_ARRAY_SHADOW_ARB 0x900D
#define GL_INT_SAMPLER_CUBE_MAP_ARRAY_ARB 0x900E
#define GL_UNSIGNED_INT_SAMPLER_CUBE_MAP_ARRAY_ARB 0x900F

#define GL_MIN_PROGRAM_TEXTURE_GATHER_OFFSET_ARB 0x8E5E
#define GL_MAX_PROGRAM_TEXTURE_GATHER_OFFSET_ARB 0x8E5F
#define GL_MAX_PROGRAM_TEXTURE_GATHER_COMPONENTS_ARB 0x8F9F

#define GL_TRANSFORM_FEEDBACK_PAUSED      0x8E23
#define GL_TRANSFORM_FEEDBACK_ACTIVE      0x8E24

#define GL_MAX_GEOMETRY_UNIFORM_BLOCKS    0x8A2C
#define GL_MAX_COMBINED_GEOMETRY_UNIFORM_COMPONENTS 0x8A32
#define GL_UNIFORM_BLOCK_REFERENCED_BY_GEOMETRY_SHADER 0x8A45

#define GL_COMPRESSED_RGBA_ASTC_4x4_KHR   0x93B0
#define GL_COMPRESSED_RGBA_ASTC_5x4_KHR   0x93B1
#define GL_COMPRESSED_RGBA_ASTC_5x5_KHR   0x93B2
#define GL_COMPRESSED_RGBA_ASTC_6x5_KHR   0x93B3
#define GL_COMPRESSED_RGBA_ASTC_6x6_KHR   0x93B4
#define GL_COMPRESSED_RGBA_ASTC_8x5_KHR   0x93B5
#define GL_COMPRESSED_RGBA_ASTC_8x6_KHR   0x93B6
#define GL_COMPRESSED_RGBA_ASTC_8x8_KHR   0x93B7
#define GL_COMPRESSED_RGBA_ASTC_10x5_KHR  0x93B8
#define GL_COMPRESSED_RGBA_ASTC_10x6_KHR  0x93B9
#define GL_COMPRESSED_RGBA_ASTC_10x8_KHR  0x93BA
#define GL_COMPRESSED_RGBA_ASTC_10x10_KHR 0x93BB
#define GL_COMPRESSED_RGBA_ASTC_12x10_KHR 0x93BC
#define GL_COMPRESSED_RGBA_ASTC_12x12_KHR 0x93BD
#define GL_COMPRESSED_SRGB8_ALPHA8_ASTC_4x4_KHR 0x93D0
#define GL_COMPRESSED_SRGB8_ALPHA8_ASTC_5x4_KHR 0x93D1
#define GL_COMPRESSED_SRGB8_ALPHA8_ASTC_5x5_KHR 0x93D2
#define GL_COMPRESSED_SRGB8_ALPHA8_ASTC_6x5_KHR 0x93D3
#define GL_COMPRESSED_SRGB8_ALPHA8_ASTC_6x6_KHR 0x93D4
#define GL_COMPRESSED_SRGB8_ALPHA8_ASTC_8x5_KHR 0x93D5
#define GL_COMPRESSED_SRGB8_ALPHA8_ASTC_8x6_KHR 0x93D6
#define GL_COMPRESSED_SRGB8_ALPHA8_ASTC_8x8_KHR 0x93D7
#define GL_COMPRESSED_SRGB8_ALPHA8_ASTC_10x5_KHR 0x93D8
#define GL_COMPRESSED_SRGB8_ALPHA8_ASTC_10x6_KHR 0x93D9
#define GL_COMPRESSED_SRGB8_ALPHA8_ASTC_10x8_KHR 0x93DA
#define GL_COMPRESSED_SRGB8_ALPHA8_ASTC_10x10_KHR 0x93DB
#define GL_COMPRESSED_SRGB8_ALPHA8_ASTC_12x10_KHR 0x93DC
#define GL_COMPRESSED_SRGB8_ALPHA8_ASTC_12x12_KHR 0x93DD
\]\]

local openGL = {
	GL = {},
	gl = {},
	loader = nil,

	import = function(self)
		rawset(_G, "GL", self.GL)
		rawset(_G, "gl", self.gl)
	end
}

if ffi.os == "Windows" then
	glheader = glheader:gsub("APIENTRYP", "__stdcall *")
	glheader = glheader:gsub("APIENTRY", "__stdcall")
else
	glheader = glheader:gsub("APIENTRYP", "*")
	glheader = glheader:gsub("APIENTRY", "")
end

local type_glenum = ffi.typeof("unsigned int")
local type_uint64 = ffi.typeof("uint64_t")

local function constant_replace(name, value)
	local ctype = type_glenum
	local GL = openGL.GL

	local num = tonumber(value)
	if (not num) then
		if (value:match("ull$")) then
			--Potentially reevaluate this for LuaJIT 2.1
			GL\[name\] = loadstring("return " .. value)()
		elseif (value:match("u$")) then
			value = value:gsub("u$", "")
			num = tonumber(value)
		end
	end
	
	GL\[name\] = GL\[name\] or ctype(num)
	
	return ""
end

glheader = glheader:gsub("#define GL_(%S+)%s+(%S+)\n", constant_replace)

ffi.cdef(glheader)

local gl_mt = {
	__index = function(self, name)
		local glname = "gl" .. name
		local procname = "PFNGL" .. name:upper() .. "PROC"
		local func = ffi.cast(procname, openGL.loader(glname))
		rawset(self, name, func)
		return func
	end
}

setmetatable(openGL.gl, gl_mt)

-- Note: You'll need to make sure the appropriate LibGL is loaded.
-- SDL2 will do this when you call SDL_Init(SDL_INIT_VIDEO), for example.

return openGL
]]):gsub('\\([%]%[])','%1')
sources["hate.window"]=([[-- <pack hate.window> --
local current_folder = (...):gsub('%.\[^%.\]+$', '') .. "."
local sdl = require(current_folder .. "sdl2")
local ffi = require "ffi"
local window = {}

-- TODO: EVERYTHING
-- Note: you almost definitely want graphics.getDimensions, not this!
function window.getDimensions()
   local w, h = ffi.new("int\[1\]"), ffi.new("int\[1\]")
   sdl.getWindowSize(window._state.window, w, h)

   return tonumber(w\[0\]), tonumber(h\[0\])
end

function window.getWidth()
   return select(1, window.getDimensions())
end

function window.getHeight()
   return select(2, window.getDimensions())
end

function window.getTitle()
   return ffi.string(sdl.getWindowTitle(window._state.window))
end

function window.setTitle(title)
   assert(type(title) == "string", "hate.window.setTitle expects one parameter of type 'string'")
   sdl.setWindowTitle(window._state.window, title)
end

function window.setFullscreen(fullscreen, fstype)
   if fullscreen then
      local flags = fstype == "desktop" and sdl.WINDOW_FULLSCREEN_DESKTOP or sdl.WINDOW_FULLSCREEN
      sdl.setWindowFullscreen(window._state.window, flags)
   else
      -- TODO: should restore/set windowed mode.
   end
end

return window
]]):gsub('\\([%]%[])','%1')
sources["hate.system"]=([[-- <pack hate.system> --
local current_folder = (...):gsub('%.\[^%.\]+$', '') .. "."
local sdl = require(current_folder .. "sdl2")
local ffi = require "ffi"

local system = {}

function system.getClipboardText()
   if sdl.hasClipboardText() then
      return ffi.string(sdl.getClipboardText())
   end
end

function system.setClipboardText(text)
   sdl.setClipboardText(text)
end

function system.getOS()
   return ffi.string(sdl.getPlatform())
end

function system.getPowerInfo()
   local percent, seconds = ffi.new("int\[1\]"), ffi.new("int\[1\]")
   local state = sdl.getPowerInfo(percent, seconds)
   local states = {
      \[tonumber(sdl.POWERSTATE_UNKNOWN)\] = "unknown",
      \[tonumber(sdl.POWERSTATE_ON_BATTERY)\] = "battery",
      \[tonumber(sdl.POWERSTATE_NO_BATTERY)\] = "nobattery",
      \[tonumber(sdl.POWERSTATE_CHARGING)\] = "charging",
      \[tonumber(sdl.POWERSTATE_CHARGED)\] = "charged"
   }
   return states\[tonumber(state)\],
          percent\[0\] >= 0 and percent\[0\] or nil,
          seconds\[0\] >= 0 and seconds\[0\] or nil
end

function system.getProcessorCount()
   return tonumber(sdl.getCPUCount())
end

function system.openURL(path)
   local osname = hate.system.getOS()
   local cmds = {
      \["Windows"\] = "start \"\"",
      \["OS X"\]    = "open",
      \["Linux"\]   = "xdg-open"
   }
   if path:sub(1, 7) == "file://" then
      cmds\["Windows"\] = "explorer"
      -- Windows-ify
      if osname == "Windows" then
         path = path:sub(8):gsub("/", "\\")
      end
   end
   if not cmds\[osname\] then
      print("What /are/ birds?")
      return
   end
   local cmdstr = cmds\[osname\] .. " \"%s\""
   -- print(cmdstr, path)
   os.execute(cmdstr:format(path))
end

return system
]]):gsub('\\([%]%[])','%1')
sources["hate.filesystem"]=([[-- <pack hate.filesystem> --
local current_folder = (...):gsub('%.\[^%.\]+$', '') .. "."

local ffi = require "ffi"
local physfs = require(current_folder .. "physfs")

local filesystem = {}

-- TODO:
-- File
-- FileData
-- and everything using __NOPE__:

local __NOPE__ = function(...)
	error("not implemented :(")
end

filesystem.createDirectory = __NOPE__
filesystem.getAppdataDirectory = __NOPE__
filesystem.getIdentity = __NOPE__
filesystem.getUserDirectory = __NOPE__
filesystem.lines = __NOPE__
filesystem.load = __NOPE__
filesystem.newFile = __NOPE__
filesystem.newFileData = __NOPE__
filesystem.setIdentity = __NOPE__
filesystem.setSource = __NOPE__

function filesystem.init(path, name)
	assert(type(path) == "string", "hate.filesystem.init accepts one parameter of type 'string'")
	local status = physfs.init(path)

	if status ~= 1 then
		return false
	end

	physfs.setSaneConfig("HATE", name, "zip", 0, 0);

	status = physfs.mount(".", "", 0)

	return status ~= 0
end

function filesystem.deinit()
	physfs.deinit()
end

function filesystem.mount(archive, mountpoint, append)
	local status = physfs.mount(filesystem.getSaveDirectory() .. "/" .. archive, mountpoint, append and append or 0)
	return status ~= 0
end

-- ...this /might/ happen to return "."
function filesystem.getWorkingDirectory()
	return ffi.string(physfs.getRealDir("/"))
end

-- untested!
function filesystem.unmount(path)
	local abs_path = filesystem.getSaveDirectory() .. "/" .. path
	assert(filesystem.exists(path), "The file \"" .. path .. "\") does not exist.")
	physfs.removeFromSearchPath(filesystem.getSaveDirectory() .. "/" .. path)
end

function filesystem.getDirectoryItems(path, callback)
	local files = {}
	local list, i = physfs.enumerateFiles("/"), 0
	while list\[i\] ~= nil do
		if type(callback) == "function" then
			callback(ffi.string(list\[i\]))
		else
			table.insert(files, ffi.string(list\[i\]))
		end
		i = i + 1
	end
	physfs.freeList(list)
	return files
end

function filesystem.getLastModified(path)
	assert(filesystem.exists(path), "The file \"" .. path .. "\") does not exist.")
	return tonumber(physfs.getLastModTime(path))
end

function filesystem.getSize(path)
	assert(type(path) == "string", "hate.filesystem.getSize accepts one parameter of type 'string'")
	local f = physfs.openRead(path)
	return tonumber(physfs.fileLength(f))
end

function filesystem.getSaveDirectory()
	return physfs.getWriteDir()
end

function filesystem.remove(path)
	assert(filesystem.exists(path), "The file \"" .. path .. "\") does not exist.")
	return physfs.delete(path) ~= 0
end

function filesystem.read(path, length)
	assert(type(path) == "string", "hate.filesystem.read requires argument #1 to be of type 'string'")
	if length ~= nil then
		assert(type(length) == "number", "hate.filesystem.read requires argument #2 to be of type 'number'")
	end
	assert(filesystem.exists(path), "The file \"" .. path .. "\") does not exist.")
	local f = physfs.openRead(path)
	local bytes = length or tonumber(physfs.fileLength(f))
	local buf = ffi.new("unsigned char\[?\]", bytes)
	local read = tonumber(physfs.read(f, buf, 1, bytes))

	physfs.close(f)

	return ffi.string(buf, bytes)
end

function filesystem.append(path, data)
	local f = physfs.openAppend(path)
	local bytes = string.len(data)
	physfs.write(f, data, 1, bytes)
	physfs.close(f)
end

function filesystem.write(path, data)
	local f = physfs.openWrite(path)
	local bytes = string.len(data)
	physfs.write(f, data, 1, bytes)
	physfs.close(f)
end

function filesystem.exists(path)
	assert(type(path) == "string", "hate.filesystem.exists accepts one parameter of type 'string'")
	return physfs.exists(path) ~= 0
end

function filesystem.isFile(path)
	assert(type(path) == "string", "hate.filesystem.isFile accepts one parameter of type 'string'")
	return physfs.exists(path) ~= 0 and physfs.isDirectory(path) == 0
end

function filesystem.isDirectory(path)
	assert(type(path) == "string", "hate.filesystem.isDirectory accepts one parameter of type 'string'")
	return physfs.exists(path) ~= 0 and physfs.isDirectory(path) ~= 0
end

function filesystem.setSymlinksEnabled(value)
	assert(type(value) == "boolean", "hate.filesystem.setSymlinksEnabled accepts one parameter of type 'boolean'")
	physfs.permitSymbolicLinks(value and 1 or 0)
end

function filesystem.areSymlinksEnabled()
	return physfs.symbolicLinksPermitted() ~= 0
end

function filesystem.isSymlink(path)
	assert(type(path) == "string", "hate.filesystem.isSymlink accepts one parameter of type 'string'")
	return physfs.isSymbolicLink(path) ~= 0
end

-- we don't even have a facility for fusing, so this can only be false.
-- this is only here for LOVE compatibility.
function filesystem.isFused()
	return false
end

return filesystem
]]):gsub('\\([%]%[])','%1')
sources["hate.sdl2.defines"]=([[-- <pack hate.sdl2.defines> --
-- Function definitions which were not output by
-- the C preprocessor

local sdl

local function registerdefines(sdl)

   -- audio

   function sdl.AUDIO_BITSIZE(x)
      return bit.band(x, sdl.AUDIO_MASK_BITSIZE)
   end

   function sdl.AUDIO_ISFLOAT(x)
      return bit.band(x, sdl.AUDIO_MASK_DATATYPE) ~= 0
   end

   function sdl.AUDIO_ISBIGENDIAN(x)
      return bit.band(x, sdl.AUDIO_MASK_ENDIAN) ~= 0
   end

   function sdl.AUDIO_ISSIGNED(x)
      return bit.band(x, sdl.AUDIO_MASK_SIGNED) ~= 0
   end

   function sdl.AUDIO_ISINT(x)
      return not sdl.AUDIO_ISFLOAT(x)
   end

   function sdl.AUDIO_ISLITTLEENDIAN(x)
      return not sdl.AUDIO_ISBIGENDIAN(x)
   end

   function sdl.AUDIO_ISUNSIGNED(x)
      return not sdl.AUDIO_ISSIGNED(x)
   end

   function sdl.loadWAV(file, spec, audio_buf, audio_len)
      return sdl.loadWAV_RW(sdl.RWFromFile(file, "rb"), 1, spec, audio_buf, audio_len)
   end

   -- surface
   sdl.blitSurface = sdl.upperBlit

   function sdl.MUSTLOCK(S)
      return bit.band(S.flags, sdl.RLEACCEL)
   end

   function sdl.loadBMP(file)
      return sdl.loadBMP_RW(sdl.RWFromFile(file, 'rb'), 1)
   end

   function sdl.saveBMP(surface, file)
      return sdl.saveBMP_RW(surface, sdl.RWFromFile(file, 'wb'), 1)
   end
end

return registerdefines
]]):gsub('\\([%]%[])','%1')
sources["hate.sdl2.cdefs"]=([[-- <pack hate.sdl2.cdefs> --
-- Cut and paste from the C preprocessor output
-- Removed inline/defined functions which are not supported by luajit
-- Instead, those are defined into defines.lua
-- Note there are some tests here and there to stay cross-platform

local ffi = require 'ffi'

ffi.cdef\[\[
typedef struct _FILE FILE;
\]\]

ffi.cdef\[\[

const char * SDL_GetPlatform (void);
typedef enum
{
    SDL_FALSE = 0,
    SDL_TRUE = 1
} SDL_bool;
typedef int8_t Sint8;
typedef uint8_t Uint8;
typedef int16_t Sint16;
typedef uint16_t Uint16;
typedef int32_t Sint32;
typedef uint32_t Uint32;
typedef int64_t Sint64;
typedef uint64_t Uint64;
typedef int SDL_dummy_uint8\[(sizeof(Uint8) == 1) * 2 - 1\];
typedef int SDL_dummy_sint8\[(sizeof(Sint8) == 1) * 2 - 1\];
typedef int SDL_dummy_uint16\[(sizeof(Uint16) == 2) * 2 - 1\];
typedef int SDL_dummy_sint16\[(sizeof(Sint16) == 2) * 2 - 1\];
typedef int SDL_dummy_uint32\[(sizeof(Uint32) == 4) * 2 - 1\];
typedef int SDL_dummy_sint32\[(sizeof(Sint32) == 4) * 2 - 1\];
typedef int SDL_dummy_uint64\[(sizeof(Uint64) == 8) * 2 - 1\];
typedef int SDL_dummy_sint64\[(sizeof(Sint64) == 8) * 2 - 1\];
typedef enum
{
    DUMMY_ENUM_VALUE
} SDL_DUMMY_ENUM;
typedef int SDL_dummy_enum\[(sizeof(SDL_DUMMY_ENUM) == sizeof(int)) * 2 - 1\];
void * SDL_malloc(size_t size);
void * SDL_calloc(size_t nmemb, size_t size);
void * SDL_realloc(void *mem, size_t size);
void SDL_free(void *mem);
char * SDL_getenv(const char *name);
int SDL_setenv(const char *name, const char *value, int overwrite);
void SDL_qsort(void *base, size_t nmemb, size_t size, int (*compare) (const void *, const void *));
int SDL_abs(int x);
int SDL_isdigit(int x);
int SDL_isspace(int x);
int SDL_toupper(int x);
int SDL_tolower(int x);
void * SDL_memset(void *dst, int c, size_t len);
void * SDL_memcpy(void *dst, const void *src, size_t len);
void * SDL_memmove(void *dst, const void *src, size_t len);
int SDL_memcmp(const void *s1, const void *s2, size_t len);
size_t SDL_wcslen(const wchar_t *wstr);
size_t SDL_wcslcpy(wchar_t *dst, const wchar_t *src, size_t maxlen);
size_t SDL_wcslcat(wchar_t *dst, const wchar_t *src, size_t maxlen);
size_t SDL_strlen(const char *str);
size_t SDL_strlcpy(char *dst, const char *src, size_t maxlen);
size_t SDL_utf8strlcpy(char *dst, const char *src, size_t dst_bytes);
size_t SDL_strlcat(char *dst, const char *src, size_t maxlen);
char * SDL_strdup(const char *str);
char * SDL_strrev(char *str);
char * SDL_strupr(char *str);
char * SDL_strlwr(char *str);
char * SDL_strchr(const char *str, int c);
char * SDL_strrchr(const char *str, int c);
char * SDL_strstr(const char *haystack, const char *needle);
char * SDL_itoa(int value, char *str, int radix);
char * SDL_uitoa(unsigned int value, char *str, int radix);
char * SDL_ltoa(long value, char *str, int radix);
char * SDL_ultoa(unsigned long value, char *str, int radix);
char * SDL_lltoa(Sint64 value, char *str, int radix);
char * SDL_ulltoa(Uint64 value, char *str, int radix);
int SDL_atoi(const char *str);
double SDL_atof(const char *str);
long SDL_strtol(const char *str, char **endp, int base);
unsigned long SDL_strtoul(const char *str, char **endp, int base);
Sint64 SDL_strtoll(const char *str, char **endp, int base);
Uint64 SDL_strtoull(const char *str, char **endp, int base);
double SDL_strtod(const char *str, char **endp);
int SDL_strcmp(const char *str1, const char *str2);
int SDL_strncmp(const char *str1, const char *str2, size_t maxlen);
int SDL_strcasecmp(const char *str1, const char *str2);
int SDL_strncasecmp(const char *str1, const char *str2, size_t len);
int SDL_sscanf(const char *text, const char *fmt, ...);
int SDL_snprintf(char *text, size_t maxlen, const char *fmt, ...);
int SDL_vsnprintf(char *text, size_t maxlen, const char *fmt, va_list ap);
double SDL_atan(double x);
double SDL_atan2(double x, double y);
double SDL_ceil(double x);
double SDL_copysign(double x, double y);
double SDL_cos(double x);
float SDL_cosf(float x);
double SDL_fabs(double x);
double SDL_floor(double x);
double SDL_log(double x);
double SDL_pow(double x, double y);
double SDL_scalbn(double x, int n);
double SDL_sin(double x);
float SDL_sinf(float x);
double SDL_sqrt(double x);
typedef struct _SDL_iconv_t *SDL_iconv_t;
SDL_iconv_t SDL_iconv_open(const char *tocode,
                                                   const char *fromcode);
int SDL_iconv_close(SDL_iconv_t cd);
size_t SDL_iconv(SDL_iconv_t cd, const char **inbuf,
                                         size_t * inbytesleft, char **outbuf,
                                         size_t * outbytesleft);
char * SDL_iconv_string(const char *tocode,
                                               const char *fromcode,
                                               const char *inbuf,
                                               size_t inbytesleft);
int SDL_main(int argc, char *argv\[\]);
void SDL_SetMainReady(void);
typedef enum
{
    SDL_ASSERTION_RETRY,
    SDL_ASSERTION_BREAK,
    SDL_ASSERTION_ABORT,
    SDL_ASSERTION_IGNORE,
    SDL_ASSERTION_ALWAYS_IGNORE
} SDL_assert_state;
typedef struct SDL_assert_data
{
    int always_ignore;
    unsigned int trigger_count;
    const char *condition;
    const char *filename;
    int linenum;
    const char *function;
    const struct SDL_assert_data *next;
} SDL_assert_data;
SDL_assert_state SDL_ReportAssertion(SDL_assert_data *,
                                                             const char *,
                                                             const char *, int);
typedef SDL_assert_state ( *SDL_AssertionHandler)(
                                 const SDL_assert_data* data, void* userdata);
void SDL_SetAssertionHandler(
                                            SDL_AssertionHandler handler,
                                            void *userdata);
const SDL_assert_data * SDL_GetAssertionReport(void);
void SDL_ResetAssertionReport(void);
typedef int SDL_SpinLock;
SDL_bool SDL_AtomicTryLock(SDL_SpinLock *lock);
void SDL_AtomicLock(SDL_SpinLock *lock);
void SDL_AtomicUnlock(SDL_SpinLock *lock);
typedef struct { int value; } SDL_atomic_t;
int SDL_SetError(const char *fmt, ...);
const char * SDL_GetError(void);
void SDL_ClearError(void);
typedef enum
{
    SDL_ENOMEM,
    SDL_EFREAD,
    SDL_EFWRITE,
    SDL_EFSEEK,
    SDL_UNSUPPORTED,
    SDL_LASTERROR
} SDL_errorcode;
int SDL_Error(SDL_errorcode code);
struct SDL_mutex;
typedef struct SDL_mutex SDL_mutex;
SDL_mutex * SDL_CreateMutex(void);
int SDL_LockMutex(SDL_mutex * mutex);
int SDL_TryLockMutex(SDL_mutex * mutex);
int SDL_UnlockMutex(SDL_mutex * mutex);
void SDL_DestroyMutex(SDL_mutex * mutex);
struct SDL_semaphore;
typedef struct SDL_semaphore SDL_sem;
SDL_sem * SDL_CreateSemaphore(Uint32 initial_value);
void SDL_DestroySemaphore(SDL_sem * sem);
int SDL_SemWait(SDL_sem * sem);
int SDL_SemTryWait(SDL_sem * sem);
int SDL_SemWaitTimeout(SDL_sem * sem, Uint32 ms);
int SDL_SemPost(SDL_sem * sem);
Uint32 SDL_SemValue(SDL_sem * sem);
struct SDL_cond;
typedef struct SDL_cond SDL_cond;
SDL_cond * SDL_CreateCond(void);
void SDL_DestroyCond(SDL_cond * cond);
int SDL_CondSignal(SDL_cond * cond);
int SDL_CondBroadcast(SDL_cond * cond);
int SDL_CondWait(SDL_cond * cond, SDL_mutex * mutex);
int SDL_CondWaitTimeout(SDL_cond * cond,
                                                SDL_mutex * mutex, Uint32 ms);
struct SDL_Thread;
typedef struct SDL_Thread SDL_Thread;
typedef unsigned long SDL_threadID;
typedef unsigned int SDL_TLSID;
typedef enum {
    SDL_THREAD_PRIORITY_LOW,
    SDL_THREAD_PRIORITY_NORMAL,
    SDL_THREAD_PRIORITY_HIGH
} SDL_ThreadPriority;
typedef int ( * SDL_ThreadFunction) (void *data);
\]\]

if jit.os == 'Windows' then
  ffi.cdef\[\[

typedef uintptr_t (*pfnSDL_CurrentBeginThread) (void *, unsigned,
						unsigned (*func)(void*),
						void *arg, unsigned,
						unsigned *threadID);

typedef void (*pfnSDL_CurrentEndThread) (unsigned code);

uintptr_t _beginthreadex(void *, unsigned,
			 unsigned (*func)(void*),
			 void *arg, unsigned,
			 unsigned *threadID);

void _endthreadex(unsigned retval);

/* note: this fails. why?
   pfnSDL_CurrentBeginThread _beginthreadex;
   pfnSDL_CurrentEndThread _endthreadex;
*/

SDL_Thread *
SDL_CreateThread(SDL_ThreadFunction fn, const char *name, void *data,
                 pfnSDL_CurrentBeginThread pfnBeginThread,
                 pfnSDL_CurrentEndThread pfnEndThread);
\]\]
else
  ffi.cdef\[\[
SDL_Thread *
SDL_CreateThread(SDL_ThreadFunction fn, const char *name, void *data);
\]\]
end

ffi.cdef\[\[
const char * SDL_GetThreadName(SDL_Thread *thread);
SDL_threadID SDL_ThreadID(void);
SDL_threadID SDL_GetThreadID(SDL_Thread * thread);
int SDL_SetThreadPriority(SDL_ThreadPriority priority);
void SDL_WaitThread(SDL_Thread * thread, int *status);
SDL_TLSID SDL_TLSCreate(void);
void * SDL_TLSGet(SDL_TLSID id);
int SDL_TLSSet(SDL_TLSID id, const void *value, void (*destructor)(void*));
typedef struct SDL_RWops
{
    Sint64 ( * size) (struct SDL_RWops * context);
    Sint64 ( * seek) (struct SDL_RWops * context, Sint64 offset,
                             int whence);
    size_t ( * read) (struct SDL_RWops * context, void *ptr,
                             size_t size, size_t maxnum);
    size_t ( * write) (struct SDL_RWops * context, const void *ptr,
                              size_t size, size_t num);
    int ( * close) (struct SDL_RWops * context);
    Uint32 type;
    union
    {
        struct
        {
            SDL_bool autoclose;
            FILE *fp;
        } stdio;
        struct
        {
            Uint8 *base;
            Uint8 *here;
            Uint8 *stop;
        } mem;
        struct
        {
            void *data1;
            void *data2;
        } unknown;
    } hidden;
} SDL_RWops;
SDL_RWops * SDL_RWFromFile(const char *file,
                                                  const char *mode);
SDL_RWops * SDL_RWFromFP(FILE * fp,
                                                SDL_bool autoclose);
SDL_RWops * SDL_RWFromMem(void *mem, int size);
SDL_RWops * SDL_RWFromConstMem(const void *mem,
                                                      int size);
SDL_RWops * SDL_AllocRW(void);
void SDL_FreeRW(SDL_RWops * area);
Uint8 SDL_ReadU8(SDL_RWops * src);
Uint16 SDL_ReadLE16(SDL_RWops * src);
Uint16 SDL_ReadBE16(SDL_RWops * src);
Uint32 SDL_ReadLE32(SDL_RWops * src);
Uint32 SDL_ReadBE32(SDL_RWops * src);
Uint64 SDL_ReadLE64(SDL_RWops * src);
Uint64 SDL_ReadBE64(SDL_RWops * src);
size_t SDL_WriteU8(SDL_RWops * dst, Uint8 value);
size_t SDL_WriteLE16(SDL_RWops * dst, Uint16 value);
size_t SDL_WriteBE16(SDL_RWops * dst, Uint16 value);
size_t SDL_WriteLE32(SDL_RWops * dst, Uint32 value);
size_t SDL_WriteBE32(SDL_RWops * dst, Uint32 value);
size_t SDL_WriteLE64(SDL_RWops * dst, Uint64 value);
size_t SDL_WriteBE64(SDL_RWops * dst, Uint64 value);
typedef Uint16 SDL_AudioFormat;
typedef void ( * SDL_AudioCallback) (void *userdata, Uint8 * stream,
                                            int len);
typedef struct SDL_AudioSpec
{
    int freq;
    SDL_AudioFormat format;
    Uint8 channels;
    Uint8 silence;
    Uint16 samples;
    Uint16 padding;
    Uint32 size;
    SDL_AudioCallback callback;
    void *userdata;
} SDL_AudioSpec;
struct SDL_AudioCVT;
typedef void ( * SDL_AudioFilter) (struct SDL_AudioCVT * cvt,
                                          SDL_AudioFormat format);
typedef struct SDL_AudioCVT
{
    int needed;
    SDL_AudioFormat src_format;
    SDL_AudioFormat dst_format;
    double rate_incr;
    Uint8 *buf;
    int len;
    int len_cvt;
    int len_mult;
    double len_ratio;
    SDL_AudioFilter filters\[10\];
    int filter_index;
} __attribute__((packed)) SDL_AudioCVT;
int SDL_GetNumAudioDrivers(void);
const char * SDL_GetAudioDriver(int index);
int SDL_AudioInit(const char *driver_name);
void SDL_AudioQuit(void);
const char * SDL_GetCurrentAudioDriver(void);
int SDL_OpenAudio(SDL_AudioSpec * desired,
                                          SDL_AudioSpec * obtained);
typedef Uint32 SDL_AudioDeviceID;
int SDL_GetNumAudioDevices(int iscapture);
const char * SDL_GetAudioDeviceName(int index,
                                                           int iscapture);
SDL_AudioDeviceID SDL_OpenAudioDevice(const char
                                                              *device,
                                                              int iscapture,
                                                              const
                                                              SDL_AudioSpec *
                                                              desired,
                                                              SDL_AudioSpec *
                                                              obtained,
                                                              int
                                                              allowed_changes);
typedef enum
{
    SDL_AUDIO_STOPPED = 0,
    SDL_AUDIO_PLAYING,
    SDL_AUDIO_PAUSED
} SDL_AudioStatus;
SDL_AudioStatus SDL_GetAudioStatus(void);
SDL_AudioStatus
SDL_GetAudioDeviceStatus(SDL_AudioDeviceID dev);
void SDL_PauseAudio(int pause_on);
void SDL_PauseAudioDevice(SDL_AudioDeviceID dev,
                                                  int pause_on);
SDL_AudioSpec * SDL_LoadWAV_RW(SDL_RWops * src,
                                                      int freesrc,
                                                      SDL_AudioSpec * spec,
                                                      Uint8 ** audio_buf,
                                                      Uint32 * audio_len);
void SDL_FreeWAV(Uint8 * audio_buf);
int SDL_BuildAudioCVT(SDL_AudioCVT * cvt,
                                              SDL_AudioFormat src_format,
                                              Uint8 src_channels,
                                              int src_rate,
                                              SDL_AudioFormat dst_format,
                                              Uint8 dst_channels,
                                              int dst_rate);
int SDL_ConvertAudio(SDL_AudioCVT * cvt);
void SDL_MixAudio(Uint8 * dst, const Uint8 * src,
                                          Uint32 len, int volume);
void SDL_MixAudioFormat(Uint8 * dst,
                                                const Uint8 * src,
                                                SDL_AudioFormat format,
                                                Uint32 len, int volume);
void SDL_LockAudio(void);
void SDL_LockAudioDevice(SDL_AudioDeviceID dev);
void SDL_UnlockAudio(void);
void SDL_UnlockAudioDevice(SDL_AudioDeviceID dev);
void SDL_CloseAudio(void);
void SDL_CloseAudioDevice(SDL_AudioDeviceID dev);
int SDL_SetClipboardText(const char *text);
char * SDL_GetClipboardText(void);
SDL_bool SDL_HasClipboardText(void);
int SDL_GetCPUCount(void);
int SDL_GetCPUCacheLineSize(void);
SDL_bool SDL_HasRDTSC(void);
SDL_bool SDL_HasAltiVec(void);
SDL_bool SDL_HasMMX(void);
SDL_bool SDL_Has3DNow(void);
SDL_bool SDL_HasSSE(void);
SDL_bool SDL_HasSSE2(void);
SDL_bool SDL_HasSSE3(void);
SDL_bool SDL_HasSSE41(void);
SDL_bool SDL_HasSSE42(void);
enum
{
    SDL_PIXELTYPE_UNKNOWN,
    SDL_PIXELTYPE_INDEX1,
    SDL_PIXELTYPE_INDEX4,
    SDL_PIXELTYPE_INDEX8,
    SDL_PIXELTYPE_PACKED8,
    SDL_PIXELTYPE_PACKED16,
    SDL_PIXELTYPE_PACKED32,
    SDL_PIXELTYPE_ARRAYU8,
    SDL_PIXELTYPE_ARRAYU16,
    SDL_PIXELTYPE_ARRAYU32,
    SDL_PIXELTYPE_ARRAYF16,
    SDL_PIXELTYPE_ARRAYF32
};
enum
{
    SDL_BITMAPORDER_NONE,
    SDL_BITMAPORDER_4321,
    SDL_BITMAPORDER_1234
};
enum
{
    SDL_PACKEDORDER_NONE,
    SDL_PACKEDORDER_XRGB,
    SDL_PACKEDORDER_RGBX,
    SDL_PACKEDORDER_ARGB,
    SDL_PACKEDORDER_RGBA,
    SDL_PACKEDORDER_XBGR,
    SDL_PACKEDORDER_BGRX,
    SDL_PACKEDORDER_ABGR,
    SDL_PACKEDORDER_BGRA
};
enum
{
    SDL_ARRAYORDER_NONE,
    SDL_ARRAYORDER_RGB,
    SDL_ARRAYORDER_RGBA,
    SDL_ARRAYORDER_ARGB,
    SDL_ARRAYORDER_BGR,
    SDL_ARRAYORDER_BGRA,
    SDL_ARRAYORDER_ABGR
};
enum
{
    SDL_PACKEDLAYOUT_NONE,
    SDL_PACKEDLAYOUT_332,
    SDL_PACKEDLAYOUT_4444,
    SDL_PACKEDLAYOUT_1555,
    SDL_PACKEDLAYOUT_5551,
    SDL_PACKEDLAYOUT_565,
    SDL_PACKEDLAYOUT_8888,
    SDL_PACKEDLAYOUT_2101010,
    SDL_PACKEDLAYOUT_1010102
};
enum
{
    SDL_PIXELFORMAT_UNKNOWN,
    SDL_PIXELFORMAT_INDEX1LSB =
        ((1 << 28) | ((SDL_PIXELTYPE_INDEX1) << 24) | ((SDL_BITMAPORDER_4321) << 20) | ((0) << 16) | ((1) << 8) | ((0) << 0)),
    SDL_PIXELFORMAT_INDEX1MSB =
        ((1 << 28) | ((SDL_PIXELTYPE_INDEX1) << 24) | ((SDL_BITMAPORDER_1234) << 20) | ((0) << 16) | ((1) << 8) | ((0) << 0)),
    SDL_PIXELFORMAT_INDEX4LSB =
        ((1 << 28) | ((SDL_PIXELTYPE_INDEX4) << 24) | ((SDL_BITMAPORDER_4321) << 20) | ((0) << 16) | ((4) << 8) | ((0) << 0)),
    SDL_PIXELFORMAT_INDEX4MSB =
        ((1 << 28) | ((SDL_PIXELTYPE_INDEX4) << 24) | ((SDL_BITMAPORDER_1234) << 20) | ((0) << 16) | ((4) << 8) | ((0) << 0)),
    SDL_PIXELFORMAT_INDEX8 =
        ((1 << 28) | ((SDL_PIXELTYPE_INDEX8) << 24) | ((0) << 20) | ((0) << 16) | ((8) << 8) | ((1) << 0)),
    SDL_PIXELFORMAT_RGB332 =
        ((1 << 28) | ((SDL_PIXELTYPE_PACKED8) << 24) | ((SDL_PACKEDORDER_XRGB) << 20) | ((SDL_PACKEDLAYOUT_332) << 16) | ((8) << 8) | ((1) << 0)),
    SDL_PIXELFORMAT_RGB444 =
        ((1 << 28) | ((SDL_PIXELTYPE_PACKED16) << 24) | ((SDL_PACKEDORDER_XRGB) << 20) | ((SDL_PACKEDLAYOUT_4444) << 16) | ((12) << 8) | ((2) << 0)),
    SDL_PIXELFORMAT_RGB555 =
        ((1 << 28) | ((SDL_PIXELTYPE_PACKED16) << 24) | ((SDL_PACKEDORDER_XRGB) << 20) | ((SDL_PACKEDLAYOUT_1555) << 16) | ((15) << 8) | ((2) << 0)),
    SDL_PIXELFORMAT_BGR555 =
        ((1 << 28) | ((SDL_PIXELTYPE_PACKED16) << 24) | ((SDL_PACKEDORDER_XBGR) << 20) | ((SDL_PACKEDLAYOUT_1555) << 16) | ((15) << 8) | ((2) << 0)),
    SDL_PIXELFORMAT_ARGB4444 =
        ((1 << 28) | ((SDL_PIXELTYPE_PACKED16) << 24) | ((SDL_PACKEDORDER_ARGB) << 20) | ((SDL_PACKEDLAYOUT_4444) << 16) | ((16) << 8) | ((2) << 0)),
    SDL_PIXELFORMAT_RGBA4444 =
        ((1 << 28) | ((SDL_PIXELTYPE_PACKED16) << 24) | ((SDL_PACKEDORDER_RGBA) << 20) | ((SDL_PACKEDLAYOUT_4444) << 16) | ((16) << 8) | ((2) << 0)),
    SDL_PIXELFORMAT_ABGR4444 =
        ((1 << 28) | ((SDL_PIXELTYPE_PACKED16) << 24) | ((SDL_PACKEDORDER_ABGR) << 20) | ((SDL_PACKEDLAYOUT_4444) << 16) | ((16) << 8) | ((2) << 0)),
    SDL_PIXELFORMAT_BGRA4444 =
        ((1 << 28) | ((SDL_PIXELTYPE_PACKED16) << 24) | ((SDL_PACKEDORDER_BGRA) << 20) | ((SDL_PACKEDLAYOUT_4444) << 16) | ((16) << 8) | ((2) << 0)),
    SDL_PIXELFORMAT_ARGB1555 =
        ((1 << 28) | ((SDL_PIXELTYPE_PACKED16) << 24) | ((SDL_PACKEDORDER_ARGB) << 20) | ((SDL_PACKEDLAYOUT_1555) << 16) | ((16) << 8) | ((2) << 0)),
    SDL_PIXELFORMAT_RGBA5551 =
        ((1 << 28) | ((SDL_PIXELTYPE_PACKED16) << 24) | ((SDL_PACKEDORDER_RGBA) << 20) | ((SDL_PACKEDLAYOUT_5551) << 16) | ((16) << 8) | ((2) << 0)),
    SDL_PIXELFORMAT_ABGR1555 =
        ((1 << 28) | ((SDL_PIXELTYPE_PACKED16) << 24) | ((SDL_PACKEDORDER_ABGR) << 20) | ((SDL_PACKEDLAYOUT_1555) << 16) | ((16) << 8) | ((2) << 0)),
    SDL_PIXELFORMAT_BGRA5551 =
        ((1 << 28) | ((SDL_PIXELTYPE_PACKED16) << 24) | ((SDL_PACKEDORDER_BGRA) << 20) | ((SDL_PACKEDLAYOUT_5551) << 16) | ((16) << 8) | ((2) << 0)),
    SDL_PIXELFORMAT_RGB565 =
        ((1 << 28) | ((SDL_PIXELTYPE_PACKED16) << 24) | ((SDL_PACKEDORDER_XRGB) << 20) | ((SDL_PACKEDLAYOUT_565) << 16) | ((16) << 8) | ((2) << 0)),
    SDL_PIXELFORMAT_BGR565 =
        ((1 << 28) | ((SDL_PIXELTYPE_PACKED16) << 24) | ((SDL_PACKEDORDER_XBGR) << 20) | ((SDL_PACKEDLAYOUT_565) << 16) | ((16) << 8) | ((2) << 0)),
    SDL_PIXELFORMAT_RGB24 =
        ((1 << 28) | ((SDL_PIXELTYPE_ARRAYU8) << 24) | ((SDL_ARRAYORDER_RGB) << 20) | ((0) << 16) | ((24) << 8) | ((3) << 0)),
    SDL_PIXELFORMAT_BGR24 =
        ((1 << 28) | ((SDL_PIXELTYPE_ARRAYU8) << 24) | ((SDL_ARRAYORDER_BGR) << 20) | ((0) << 16) | ((24) << 8) | ((3) << 0)),
    SDL_PIXELFORMAT_RGB888 =
        ((1 << 28) | ((SDL_PIXELTYPE_PACKED32) << 24) | ((SDL_PACKEDORDER_XRGB) << 20) | ((SDL_PACKEDLAYOUT_8888) << 16) | ((24) << 8) | ((4) << 0)),
    SDL_PIXELFORMAT_RGBX8888 =
        ((1 << 28) | ((SDL_PIXELTYPE_PACKED32) << 24) | ((SDL_PACKEDORDER_RGBX) << 20) | ((SDL_PACKEDLAYOUT_8888) << 16) | ((24) << 8) | ((4) << 0)),
    SDL_PIXELFORMAT_BGR888 =
        ((1 << 28) | ((SDL_PIXELTYPE_PACKED32) << 24) | ((SDL_PACKEDORDER_XBGR) << 20) | ((SDL_PACKEDLAYOUT_8888) << 16) | ((24) << 8) | ((4) << 0)),
    SDL_PIXELFORMAT_BGRX8888 =
        ((1 << 28) | ((SDL_PIXELTYPE_PACKED32) << 24) | ((SDL_PACKEDORDER_BGRX) << 20) | ((SDL_PACKEDLAYOUT_8888) << 16) | ((24) << 8) | ((4) << 0)),
    SDL_PIXELFORMAT_ARGB8888 =
        ((1 << 28) | ((SDL_PIXELTYPE_PACKED32) << 24) | ((SDL_PACKEDORDER_ARGB) << 20) | ((SDL_PACKEDLAYOUT_8888) << 16) | ((32) << 8) | ((4) << 0)),
    SDL_PIXELFORMAT_RGBA8888 =
        ((1 << 28) | ((SDL_PIXELTYPE_PACKED32) << 24) | ((SDL_PACKEDORDER_RGBA) << 20) | ((SDL_PACKEDLAYOUT_8888) << 16) | ((32) << 8) | ((4) << 0)),
    SDL_PIXELFORMAT_ABGR8888 =
        ((1 << 28) | ((SDL_PIXELTYPE_PACKED32) << 24) | ((SDL_PACKEDORDER_ABGR) << 20) | ((SDL_PACKEDLAYOUT_8888) << 16) | ((32) << 8) | ((4) << 0)),
    SDL_PIXELFORMAT_BGRA8888 =
        ((1 << 28) | ((SDL_PIXELTYPE_PACKED32) << 24) | ((SDL_PACKEDORDER_BGRA) << 20) | ((SDL_PACKEDLAYOUT_8888) << 16) | ((32) << 8) | ((4) << 0)),
    SDL_PIXELFORMAT_ARGB2101010 =
        ((1 << 28) | ((SDL_PIXELTYPE_PACKED32) << 24) | ((SDL_PACKEDORDER_ARGB) << 20) | ((SDL_PACKEDLAYOUT_2101010) << 16) | ((32) << 8) | ((4) << 0)),
    SDL_PIXELFORMAT_YV12 =
        ((((Uint32)(((Uint8)(('Y'))))) << 0) | (((Uint32)(((Uint8)(('V'))))) << 8) | (((Uint32)(((Uint8)(('1'))))) << 16) | (((Uint32)(((Uint8)(('2'))))) << 24)),
    SDL_PIXELFORMAT_IYUV =
        ((((Uint32)(((Uint8)(('I'))))) << 0) | (((Uint32)(((Uint8)(('Y'))))) << 8) | (((Uint32)(((Uint8)(('U'))))) << 16) | (((Uint32)(((Uint8)(('V'))))) << 24)),
    SDL_PIXELFORMAT_YUY2 =
        ((((Uint32)(((Uint8)(('Y'))))) << 0) | (((Uint32)(((Uint8)(('U'))))) << 8) | (((Uint32)(((Uint8)(('Y'))))) << 16) | (((Uint32)(((Uint8)(('2'))))) << 24)),
    SDL_PIXELFORMAT_UYVY =
        ((((Uint32)(((Uint8)(('U'))))) << 0) | (((Uint32)(((Uint8)(('Y'))))) << 8) | (((Uint32)(((Uint8)(('V'))))) << 16) | (((Uint32)(((Uint8)(('Y'))))) << 24)),
    SDL_PIXELFORMAT_YVYU =
        ((((Uint32)(((Uint8)(('Y'))))) << 0) | (((Uint32)(((Uint8)(('V'))))) << 8) | (((Uint32)(((Uint8)(('Y'))))) << 16) | (((Uint32)(((Uint8)(('U'))))) << 24))
};
typedef struct SDL_Color
{
    Uint8 r;
    Uint8 g;
    Uint8 b;
    Uint8 a;
} SDL_Color;
typedef struct SDL_Palette
{
    int ncolors;
    SDL_Color *colors;
    Uint32 version;
    int refcount;
} SDL_Palette;
typedef struct SDL_PixelFormat
{
    Uint32 format;
    SDL_Palette *palette;
    Uint8 BitsPerPixel;
    Uint8 BytesPerPixel;
    Uint8 padding\[2\];
    Uint32 Rmask;
    Uint32 Gmask;
    Uint32 Bmask;
    Uint32 Amask;
    Uint8 Rloss;
    Uint8 Gloss;
    Uint8 Bloss;
    Uint8 Aloss;
    Uint8 Rshift;
    Uint8 Gshift;
    Uint8 Bshift;
    Uint8 Ashift;
    int refcount;
    struct SDL_PixelFormat *next;
} SDL_PixelFormat;
const char* SDL_GetPixelFormatName(Uint32 format);
SDL_bool SDL_PixelFormatEnumToMasks(Uint32 format,
                                                            int *bpp,
                                                            Uint32 * Rmask,
                                                            Uint32 * Gmask,
                                                            Uint32 * Bmask,
                                                            Uint32 * Amask);
Uint32 SDL_MasksToPixelFormatEnum(int bpp,
                                                          Uint32 Rmask,
                                                          Uint32 Gmask,
                                                          Uint32 Bmask,
                                                          Uint32 Amask);
SDL_PixelFormat * SDL_AllocFormat(Uint32 pixel_format);
void SDL_FreeFormat(SDL_PixelFormat *format);
SDL_Palette * SDL_AllocPalette(int ncolors);
int SDL_SetPixelFormatPalette(SDL_PixelFormat * format,
                                                      SDL_Palette *palette);
int SDL_SetPaletteColors(SDL_Palette * palette,
                                                 const SDL_Color * colors,
                                                 int firstcolor, int ncolors);
void SDL_FreePalette(SDL_Palette * palette);
Uint32 SDL_MapRGB(const SDL_PixelFormat * format,
                                          Uint8 r, Uint8 g, Uint8 b);
Uint32 SDL_MapRGBA(const SDL_PixelFormat * format,
                                           Uint8 r, Uint8 g, Uint8 b,
                                           Uint8 a);
void SDL_GetRGB(Uint32 pixel,
                                        const SDL_PixelFormat * format,
                                        Uint8 * r, Uint8 * g, Uint8 * b);
void SDL_GetRGBA(Uint32 pixel,
                                         const SDL_PixelFormat * format,
                                         Uint8 * r, Uint8 * g, Uint8 * b,
                                         Uint8 * a);
void SDL_CalculateGammaRamp(float gamma, Uint16 * ramp);
typedef struct
{
    int x;
    int y;
} SDL_Point;
typedef struct SDL_Rect
{
    int x, y;
    int w, h;
} SDL_Rect;
SDL_bool SDL_HasIntersection(const SDL_Rect * A,
                                                     const SDL_Rect * B);
SDL_bool SDL_IntersectRect(const SDL_Rect * A,
                                                   const SDL_Rect * B,
                                                   SDL_Rect * result);
void SDL_UnionRect(const SDL_Rect * A,
                                           const SDL_Rect * B,
                                           SDL_Rect * result);
SDL_bool SDL_EnclosePoints(const SDL_Point * points,
                                                   int count,
                                                   const SDL_Rect * clip,
                                                   SDL_Rect * result);
SDL_bool SDL_IntersectRectAndLine(const SDL_Rect *
                                                          rect, int *X1,
                                                          int *Y1, int *X2,
                                                          int *Y2);
typedef enum
{
    SDL_BLENDMODE_NONE = 0x00000000,
    SDL_BLENDMODE_BLEND = 0x00000001,
    SDL_BLENDMODE_ADD = 0x00000002,
    SDL_BLENDMODE_MOD = 0x00000004
} SDL_BlendMode;
typedef struct SDL_Surface
{
    Uint32 flags;
    SDL_PixelFormat *format;
    int w, h;
    int pitch;
    void *pixels;
    void *userdata;
    int locked;
    void *lock_data;
    SDL_Rect clip_rect;
    struct SDL_BlitMap *map;
    int refcount;
} SDL_Surface;
typedef int (*SDL_blit) (struct SDL_Surface * src, SDL_Rect * srcrect,
                         struct SDL_Surface * dst, SDL_Rect * dstrect);
SDL_Surface * SDL_CreateRGBSurface
    (Uint32 flags, int width, int height, int depth,
     Uint32 Rmask, Uint32 Gmask, Uint32 Bmask, Uint32 Amask);
SDL_Surface * SDL_CreateRGBSurfaceFrom(void *pixels,
                                                              int width,
                                                              int height,
                                                              int depth,
                                                              int pitch,
                                                              Uint32 Rmask,
                                                              Uint32 Gmask,
                                                              Uint32 Bmask,
                                                              Uint32 Amask);
void SDL_FreeSurface(SDL_Surface * surface);
int SDL_SetSurfacePalette(SDL_Surface * surface,
                                                  SDL_Palette * palette);
int SDL_LockSurface(SDL_Surface * surface);
void SDL_UnlockSurface(SDL_Surface * surface);
SDL_Surface * SDL_LoadBMP_RW(SDL_RWops * src,
                                                    int freesrc);
int SDL_SaveBMP_RW
    (SDL_Surface * surface, SDL_RWops * dst, int freedst);
int SDL_SetSurfaceRLE(SDL_Surface * surface,
                                              int flag);
int SDL_SetColorKey(SDL_Surface * surface,
                                            int flag, Uint32 key);
int SDL_GetColorKey(SDL_Surface * surface,
                                            Uint32 * key);
int SDL_SetSurfaceColorMod(SDL_Surface * surface,
                                                   Uint8 r, Uint8 g, Uint8 b);
int SDL_GetSurfaceColorMod(SDL_Surface * surface,
                                                   Uint8 * r, Uint8 * g,
                                                   Uint8 * b);
int SDL_SetSurfaceAlphaMod(SDL_Surface * surface,
                                                   Uint8 alpha);
int SDL_GetSurfaceAlphaMod(SDL_Surface * surface,
                                                   Uint8 * alpha);
int SDL_SetSurfaceBlendMode(SDL_Surface * surface,
                                                    SDL_BlendMode blendMode);
int SDL_GetSurfaceBlendMode(SDL_Surface * surface,
                                                    SDL_BlendMode *blendMode);
SDL_bool SDL_SetClipRect(SDL_Surface * surface,
                                                 const SDL_Rect * rect);
void SDL_GetClipRect(SDL_Surface * surface,
                                             SDL_Rect * rect);
SDL_Surface * SDL_ConvertSurface
    (SDL_Surface * src, SDL_PixelFormat * fmt, Uint32 flags);
SDL_Surface * SDL_ConvertSurfaceFormat
    (SDL_Surface * src, Uint32 pixel_format, Uint32 flags);
int SDL_ConvertPixels(int width, int height,
                                              Uint32 src_format,
                                              const void * src, int src_pitch,
                                              Uint32 dst_format,
                                              void * dst, int dst_pitch);
int SDL_FillRect
    (SDL_Surface * dst, const SDL_Rect * rect, Uint32 color);
int SDL_FillRects
    (SDL_Surface * dst, const SDL_Rect * rects, int count, Uint32 color);
int SDL_UpperBlit
    (SDL_Surface * src, const SDL_Rect * srcrect,
     SDL_Surface * dst, SDL_Rect * dstrect);
int SDL_LowerBlit
    (SDL_Surface * src, SDL_Rect * srcrect,
     SDL_Surface * dst, SDL_Rect * dstrect);
int SDL_SoftStretch(SDL_Surface * src,
                                            const SDL_Rect * srcrect,
                                            SDL_Surface * dst,
                                            const SDL_Rect * dstrect);
int SDL_UpperBlitScaled
    (SDL_Surface * src, const SDL_Rect * srcrect,
    SDL_Surface * dst, SDL_Rect * dstrect);
int SDL_LowerBlitScaled
    (SDL_Surface * src, SDL_Rect * srcrect,
    SDL_Surface * dst, SDL_Rect * dstrect);
typedef struct
{
    Uint32 format;
    int w;
    int h;
    int refresh_rate;
    void *driverdata;
} SDL_DisplayMode;
typedef struct SDL_Window SDL_Window;
typedef enum
{
    SDL_WINDOW_FULLSCREEN = 0x00000001,
    SDL_WINDOW_OPENGL = 0x00000002,
    SDL_WINDOW_SHOWN = 0x00000004,
    SDL_WINDOW_HIDDEN = 0x00000008,
    SDL_WINDOW_BORDERLESS = 0x00000010,
    SDL_WINDOW_RESIZABLE = 0x00000020,
    SDL_WINDOW_MINIMIZED = 0x00000040,
    SDL_WINDOW_MAXIMIZED = 0x00000080,
    SDL_WINDOW_INPUT_GRABBED = 0x00000100,
    SDL_WINDOW_INPUT_FOCUS = 0x00000200,
    SDL_WINDOW_MOUSE_FOCUS = 0x00000400,
    SDL_WINDOW_FULLSCREEN_DESKTOP = ( SDL_WINDOW_FULLSCREEN | 0x00001000 ),
    SDL_WINDOW_FOREIGN = 0x00000800
} SDL_WindowFlags;
typedef enum
{
    SDL_WINDOWEVENT_NONE,
    SDL_WINDOWEVENT_SHOWN,
    SDL_WINDOWEVENT_HIDDEN,
    SDL_WINDOWEVENT_EXPOSED,
    SDL_WINDOWEVENT_MOVED,
    SDL_WINDOWEVENT_RESIZED,
    SDL_WINDOWEVENT_SIZE_CHANGED,
    SDL_WINDOWEVENT_MINIMIZED,
    SDL_WINDOWEVENT_MAXIMIZED,
    SDL_WINDOWEVENT_RESTORED,
    SDL_WINDOWEVENT_ENTER,
    SDL_WINDOWEVENT_LEAVE,
    SDL_WINDOWEVENT_FOCUS_GAINED,
    SDL_WINDOWEVENT_FOCUS_LOST,
    SDL_WINDOWEVENT_CLOSE
} SDL_WindowEventID;
typedef void *SDL_GLContext;
typedef enum
{
    SDL_GL_RED_SIZE,
    SDL_GL_GREEN_SIZE,
    SDL_GL_BLUE_SIZE,
    SDL_GL_ALPHA_SIZE,
    SDL_GL_BUFFER_SIZE,
    SDL_GL_DOUBLEBUFFER,
    SDL_GL_DEPTH_SIZE,
    SDL_GL_STENCIL_SIZE,
    SDL_GL_ACCUM_RED_SIZE,
    SDL_GL_ACCUM_GREEN_SIZE,
    SDL_GL_ACCUM_BLUE_SIZE,
    SDL_GL_ACCUM_ALPHA_SIZE,
    SDL_GL_STEREO,
    SDL_GL_MULTISAMPLEBUFFERS,
    SDL_GL_MULTISAMPLESAMPLES,
    SDL_GL_ACCELERATED_VISUAL,
    SDL_GL_RETAINED_BACKING,
    SDL_GL_CONTEXT_MAJOR_VERSION,
    SDL_GL_CONTEXT_MINOR_VERSION,
    SDL_GL_CONTEXT_EGL,
    SDL_GL_CONTEXT_FLAGS,
    SDL_GL_CONTEXT_PROFILE_MASK,
    SDL_GL_SHARE_WITH_CURRENT_CONTEXT,
    SDL_GL_FRAMEBUFFER_SRGB_CAPABLE
} SDL_GLattr;
typedef enum
{
    SDL_GL_CONTEXT_PROFILE_CORE = 0x0001,
    SDL_GL_CONTEXT_PROFILE_COMPATIBILITY = 0x0002,
    SDL_GL_CONTEXT_PROFILE_ES = 0x0004
} SDL_GLprofile;
typedef enum
{
    SDL_GL_CONTEXT_DEBUG_FLAG = 0x0001,
    SDL_GL_CONTEXT_FORWARD_COMPATIBLE_FLAG = 0x0002,
    SDL_GL_CONTEXT_ROBUST_ACCESS_FLAG = 0x0004,
    SDL_GL_CONTEXT_RESET_ISOLATION_FLAG = 0x0008
} SDL_GLcontextFlag;
int SDL_GetNumVideoDrivers(void);
const char * SDL_GetVideoDriver(int index);
int SDL_VideoInit(const char *driver_name);
void SDL_VideoQuit(void);
const char * SDL_GetCurrentVideoDriver(void);
int SDL_GetNumVideoDisplays(void);
const char * SDL_GetDisplayName(int displayIndex);
int SDL_GetDisplayBounds(int displayIndex, SDL_Rect * rect);
int SDL_GetNumDisplayModes(int displayIndex);
int SDL_GetDisplayMode(int displayIndex, int modeIndex,
                                               SDL_DisplayMode * mode);
int SDL_GetDesktopDisplayMode(int displayIndex, SDL_DisplayMode * mode);
int SDL_GetCurrentDisplayMode(int displayIndex, SDL_DisplayMode * mode);
SDL_DisplayMode * SDL_GetClosestDisplayMode(int displayIndex, const SDL_DisplayMode * mode, SDL_DisplayMode * closest);
int SDL_GetWindowDisplayIndex(SDL_Window * window);
int SDL_SetWindowDisplayMode(SDL_Window * window,
                                                     const SDL_DisplayMode
                                                         * mode);
int SDL_GetWindowDisplayMode(SDL_Window * window,
                                                     SDL_DisplayMode * mode);
Uint32 SDL_GetWindowPixelFormat(SDL_Window * window);
SDL_Window * SDL_CreateWindow(const char *title,
                                                      int x, int y, int w,
                                                      int h, Uint32 flags);
SDL_Window * SDL_CreateWindowFrom(const void *data);
Uint32 SDL_GetWindowID(SDL_Window * window);
SDL_Window * SDL_GetWindowFromID(Uint32 id);
Uint32 SDL_GetWindowFlags(SDL_Window * window);
void SDL_SetWindowTitle(SDL_Window * window,
                                                const char *title);
const char * SDL_GetWindowTitle(SDL_Window * window);
void SDL_SetWindowIcon(SDL_Window * window,
                                               SDL_Surface * icon);
void* SDL_SetWindowData(SDL_Window * window,
                                                const char *name,
                                                void *userdata);
void * SDL_GetWindowData(SDL_Window * window,
                                                const char *name);
void SDL_SetWindowPosition(SDL_Window * window,
                                                   int x, int y);
void SDL_GetWindowPosition(SDL_Window * window,
                                                   int *x, int *y);
void SDL_SetWindowSize(SDL_Window * window, int w,
                                               int h);
void SDL_GetWindowSize(SDL_Window * window, int *w,
                                               int *h);
void SDL_SetWindowMinimumSize(SDL_Window * window,
                                                      int min_w, int min_h);
void SDL_GetWindowMinimumSize(SDL_Window * window,
                                                      int *w, int *h);
void SDL_SetWindowMaximumSize(SDL_Window * window,
                                                      int max_w, int max_h);
void SDL_GetWindowMaximumSize(SDL_Window * window,
                                                      int *w, int *h);
void SDL_SetWindowBordered(SDL_Window * window,
                                                   SDL_bool bordered);
void SDL_ShowWindow(SDL_Window * window);
void SDL_HideWindow(SDL_Window * window);
void SDL_RaiseWindow(SDL_Window * window);
void SDL_MaximizeWindow(SDL_Window * window);
void SDL_MinimizeWindow(SDL_Window * window);
void SDL_RestoreWindow(SDL_Window * window);
int SDL_SetWindowFullscreen(SDL_Window * window,
                                                    Uint32 flags);
SDL_Surface * SDL_GetWindowSurface(SDL_Window * window);
int SDL_UpdateWindowSurface(SDL_Window * window);
int SDL_UpdateWindowSurfaceRects(SDL_Window * window,
                                                         const SDL_Rect * rects,
                                                         int numrects);
void SDL_SetWindowGrab(SDL_Window * window,
                                               SDL_bool grabbed);
SDL_bool SDL_GetWindowGrab(SDL_Window * window);
int SDL_SetWindowBrightness(SDL_Window * window, float brightness);
float SDL_GetWindowBrightness(SDL_Window * window);
int SDL_SetWindowGammaRamp(SDL_Window * window,
                                                   const Uint16 * red,
                                                   const Uint16 * green,
                                                   const Uint16 * blue);
int SDL_GetWindowGammaRamp(SDL_Window * window,
                                                   Uint16 * red,
                                                   Uint16 * green,
                                                   Uint16 * blue);
void SDL_DestroyWindow(SDL_Window * window);
SDL_bool SDL_IsScreenSaverEnabled(void);
void SDL_EnableScreenSaver(void);
void SDL_DisableScreenSaver(void);
int SDL_GL_LoadLibrary(const char *path);
void * SDL_GL_GetProcAddress(const char *proc);
void SDL_GL_UnloadLibrary(void);
SDL_bool SDL_GL_ExtensionSupported(const char
                                                           *extension);
int SDL_GL_SetAttribute(SDL_GLattr attr, int value);
int SDL_GL_GetAttribute(SDL_GLattr attr, int *value);
SDL_GLContext SDL_GL_CreateContext(SDL_Window *
                                                           window);
int SDL_GL_MakeCurrent(SDL_Window * window,
                                               SDL_GLContext context);
void SDL_GL_GetDrawableSize(SDL_Window *window, int *w, int *h);

SDL_Window* SDL_GL_GetCurrentWindow(void);
SDL_GLContext SDL_GL_GetCurrentContext(void);
int SDL_GL_SetSwapInterval(int interval);
int SDL_GL_GetSwapInterval(void);
void SDL_GL_SwapWindow(SDL_Window * window);
void SDL_GL_DeleteContext(SDL_GLContext context);
typedef enum
{
    SDL_SCANCODE_UNKNOWN = 0,
    SDL_SCANCODE_A = 4,
    SDL_SCANCODE_B = 5,
    SDL_SCANCODE_C = 6,
    SDL_SCANCODE_D = 7,
    SDL_SCANCODE_E = 8,
    SDL_SCANCODE_F = 9,
    SDL_SCANCODE_G = 10,
    SDL_SCANCODE_H = 11,
    SDL_SCANCODE_I = 12,
    SDL_SCANCODE_J = 13,
    SDL_SCANCODE_K = 14,
    SDL_SCANCODE_L = 15,
    SDL_SCANCODE_M = 16,
    SDL_SCANCODE_N = 17,
    SDL_SCANCODE_O = 18,
    SDL_SCANCODE_P = 19,
    SDL_SCANCODE_Q = 20,
    SDL_SCANCODE_R = 21,
    SDL_SCANCODE_S = 22,
    SDL_SCANCODE_T = 23,
    SDL_SCANCODE_U = 24,
    SDL_SCANCODE_V = 25,
    SDL_SCANCODE_W = 26,
    SDL_SCANCODE_X = 27,
    SDL_SCANCODE_Y = 28,
    SDL_SCANCODE_Z = 29,
    SDL_SCANCODE_1 = 30,
    SDL_SCANCODE_2 = 31,
    SDL_SCANCODE_3 = 32,
    SDL_SCANCODE_4 = 33,
    SDL_SCANCODE_5 = 34,
    SDL_SCANCODE_6 = 35,
    SDL_SCANCODE_7 = 36,
    SDL_SCANCODE_8 = 37,
    SDL_SCANCODE_9 = 38,
    SDL_SCANCODE_0 = 39,
    SDL_SCANCODE_RETURN = 40,
    SDL_SCANCODE_ESCAPE = 41,
    SDL_SCANCODE_BACKSPACE = 42,
    SDL_SCANCODE_TAB = 43,
    SDL_SCANCODE_SPACE = 44,
    SDL_SCANCODE_MINUS = 45,
    SDL_SCANCODE_EQUALS = 46,
    SDL_SCANCODE_LEFTBRACKET = 47,
    SDL_SCANCODE_RIGHTBRACKET = 48,
    SDL_SCANCODE_BACKSLASH = 49,
    SDL_SCANCODE_NONUSHASH = 50,
    SDL_SCANCODE_SEMICOLON = 51,
    SDL_SCANCODE_APOSTROPHE = 52,
    SDL_SCANCODE_GRAVE = 53,
    SDL_SCANCODE_COMMA = 54,
    SDL_SCANCODE_PERIOD = 55,
    SDL_SCANCODE_SLASH = 56,
    SDL_SCANCODE_CAPSLOCK = 57,
    SDL_SCANCODE_F1 = 58,
    SDL_SCANCODE_F2 = 59,
    SDL_SCANCODE_F3 = 60,
    SDL_SCANCODE_F4 = 61,
    SDL_SCANCODE_F5 = 62,
    SDL_SCANCODE_F6 = 63,
    SDL_SCANCODE_F7 = 64,
    SDL_SCANCODE_F8 = 65,
    SDL_SCANCODE_F9 = 66,
    SDL_SCANCODE_F10 = 67,
    SDL_SCANCODE_F11 = 68,
    SDL_SCANCODE_F12 = 69,
    SDL_SCANCODE_PRINTSCREEN = 70,
    SDL_SCANCODE_SCROLLLOCK = 71,
    SDL_SCANCODE_PAUSE = 72,
    SDL_SCANCODE_INSERT = 73,
    SDL_SCANCODE_HOME = 74,
    SDL_SCANCODE_PAGEUP = 75,
    SDL_SCANCODE_DELETE = 76,
    SDL_SCANCODE_END = 77,
    SDL_SCANCODE_PAGEDOWN = 78,
    SDL_SCANCODE_RIGHT = 79,
    SDL_SCANCODE_LEFT = 80,
    SDL_SCANCODE_DOWN = 81,
    SDL_SCANCODE_UP = 82,
    SDL_SCANCODE_NUMLOCKCLEAR = 83,
    SDL_SCANCODE_KP_DIVIDE = 84,
    SDL_SCANCODE_KP_MULTIPLY = 85,
    SDL_SCANCODE_KP_MINUS = 86,
    SDL_SCANCODE_KP_PLUS = 87,
    SDL_SCANCODE_KP_ENTER = 88,
    SDL_SCANCODE_KP_1 = 89,
    SDL_SCANCODE_KP_2 = 90,
    SDL_SCANCODE_KP_3 = 91,
    SDL_SCANCODE_KP_4 = 92,
    SDL_SCANCODE_KP_5 = 93,
    SDL_SCANCODE_KP_6 = 94,
    SDL_SCANCODE_KP_7 = 95,
    SDL_SCANCODE_KP_8 = 96,
    SDL_SCANCODE_KP_9 = 97,
    SDL_SCANCODE_KP_0 = 98,
    SDL_SCANCODE_KP_PERIOD = 99,
    SDL_SCANCODE_NONUSBACKSLASH = 100,
    SDL_SCANCODE_APPLICATION = 101,
    SDL_SCANCODE_POWER = 102,
    SDL_SCANCODE_KP_EQUALS = 103,
    SDL_SCANCODE_F13 = 104,
    SDL_SCANCODE_F14 = 105,
    SDL_SCANCODE_F15 = 106,
    SDL_SCANCODE_F16 = 107,
    SDL_SCANCODE_F17 = 108,
    SDL_SCANCODE_F18 = 109,
    SDL_SCANCODE_F19 = 110,
    SDL_SCANCODE_F20 = 111,
    SDL_SCANCODE_F21 = 112,
    SDL_SCANCODE_F22 = 113,
    SDL_SCANCODE_F23 = 114,
    SDL_SCANCODE_F24 = 115,
    SDL_SCANCODE_EXECUTE = 116,
    SDL_SCANCODE_HELP = 117,
    SDL_SCANCODE_MENU = 118,
    SDL_SCANCODE_SELECT = 119,
    SDL_SCANCODE_STOP = 120,
    SDL_SCANCODE_AGAIN = 121,
    SDL_SCANCODE_UNDO = 122,
    SDL_SCANCODE_CUT = 123,
    SDL_SCANCODE_COPY = 124,
    SDL_SCANCODE_PASTE = 125,
    SDL_SCANCODE_FIND = 126,
    SDL_SCANCODE_MUTE = 127,
    SDL_SCANCODE_VOLUMEUP = 128,
    SDL_SCANCODE_VOLUMEDOWN = 129,
    SDL_SCANCODE_KP_COMMA = 133,
    SDL_SCANCODE_KP_EQUALSAS400 = 134,
    SDL_SCANCODE_INTERNATIONAL1 = 135,
    SDL_SCANCODE_INTERNATIONAL2 = 136,
    SDL_SCANCODE_INTERNATIONAL3 = 137,
    SDL_SCANCODE_INTERNATIONAL4 = 138,
    SDL_SCANCODE_INTERNATIONAL5 = 139,
    SDL_SCANCODE_INTERNATIONAL6 = 140,
    SDL_SCANCODE_INTERNATIONAL7 = 141,
    SDL_SCANCODE_INTERNATIONAL8 = 142,
    SDL_SCANCODE_INTERNATIONAL9 = 143,
    SDL_SCANCODE_LANG1 = 144,
    SDL_SCANCODE_LANG2 = 145,
    SDL_SCANCODE_LANG3 = 146,
    SDL_SCANCODE_LANG4 = 147,
    SDL_SCANCODE_LANG5 = 148,
    SDL_SCANCODE_LANG6 = 149,
    SDL_SCANCODE_LANG7 = 150,
    SDL_SCANCODE_LANG8 = 151,
    SDL_SCANCODE_LANG9 = 152,
    SDL_SCANCODE_ALTERASE = 153,
    SDL_SCANCODE_SYSREQ = 154,
    SDL_SCANCODE_CANCEL = 155,
    SDL_SCANCODE_CLEAR = 156,
    SDL_SCANCODE_PRIOR = 157,
    SDL_SCANCODE_RETURN2 = 158,
    SDL_SCANCODE_SEPARATOR = 159,
    SDL_SCANCODE_OUT = 160,
    SDL_SCANCODE_OPER = 161,
    SDL_SCANCODE_CLEARAGAIN = 162,
    SDL_SCANCODE_CRSEL = 163,
    SDL_SCANCODE_EXSEL = 164,
    SDL_SCANCODE_KP_00 = 176,
    SDL_SCANCODE_KP_000 = 177,
    SDL_SCANCODE_THOUSANDSSEPARATOR = 178,
    SDL_SCANCODE_DECIMALSEPARATOR = 179,
    SDL_SCANCODE_CURRENCYUNIT = 180,
    SDL_SCANCODE_CURRENCYSUBUNIT = 181,
    SDL_SCANCODE_KP_LEFTPAREN = 182,
    SDL_SCANCODE_KP_RIGHTPAREN = 183,
    SDL_SCANCODE_KP_LEFTBRACE = 184,
    SDL_SCANCODE_KP_RIGHTBRACE = 185,
    SDL_SCANCODE_KP_TAB = 186,
    SDL_SCANCODE_KP_BACKSPACE = 187,
    SDL_SCANCODE_KP_A = 188,
    SDL_SCANCODE_KP_B = 189,
    SDL_SCANCODE_KP_C = 190,
    SDL_SCANCODE_KP_D = 191,
    SDL_SCANCODE_KP_E = 192,
    SDL_SCANCODE_KP_F = 193,
    SDL_SCANCODE_KP_XOR = 194,
    SDL_SCANCODE_KP_POWER = 195,
    SDL_SCANCODE_KP_PERCENT = 196,
    SDL_SCANCODE_KP_LESS = 197,
    SDL_SCANCODE_KP_GREATER = 198,
    SDL_SCANCODE_KP_AMPERSAND = 199,
    SDL_SCANCODE_KP_DBLAMPERSAND = 200,
    SDL_SCANCODE_KP_VERTICALBAR = 201,
    SDL_SCANCODE_KP_DBLVERTICALBAR = 202,
    SDL_SCANCODE_KP_COLON = 203,
    SDL_SCANCODE_KP_HASH = 204,
    SDL_SCANCODE_KP_SPACE = 205,
    SDL_SCANCODE_KP_AT = 206,
    SDL_SCANCODE_KP_EXCLAM = 207,
    SDL_SCANCODE_KP_MEMSTORE = 208,
    SDL_SCANCODE_KP_MEMRECALL = 209,
    SDL_SCANCODE_KP_MEMCLEAR = 210,
    SDL_SCANCODE_KP_MEMADD = 211,
    SDL_SCANCODE_KP_MEMSUBTRACT = 212,
    SDL_SCANCODE_KP_MEMMULTIPLY = 213,
    SDL_SCANCODE_KP_MEMDIVIDE = 214,
    SDL_SCANCODE_KP_PLUSMINUS = 215,
    SDL_SCANCODE_KP_CLEAR = 216,
    SDL_SCANCODE_KP_CLEARENTRY = 217,
    SDL_SCANCODE_KP_BINARY = 218,
    SDL_SCANCODE_KP_OCTAL = 219,
    SDL_SCANCODE_KP_DECIMAL = 220,
    SDL_SCANCODE_KP_HEXADECIMAL = 221,
    SDL_SCANCODE_LCTRL = 224,
    SDL_SCANCODE_LSHIFT = 225,
    SDL_SCANCODE_LALT = 226,
    SDL_SCANCODE_LGUI = 227,
    SDL_SCANCODE_RCTRL = 228,
    SDL_SCANCODE_RSHIFT = 229,
    SDL_SCANCODE_RALT = 230,
    SDL_SCANCODE_RGUI = 231,
    SDL_SCANCODE_MODE = 257,
    SDL_SCANCODE_AUDIONEXT = 258,
    SDL_SCANCODE_AUDIOPREV = 259,
    SDL_SCANCODE_AUDIOSTOP = 260,
    SDL_SCANCODE_AUDIOPLAY = 261,
    SDL_SCANCODE_AUDIOMUTE = 262,
    SDL_SCANCODE_MEDIASELECT = 263,
    SDL_SCANCODE_WWW = 264,
    SDL_SCANCODE_MAIL = 265,
    SDL_SCANCODE_CALCULATOR = 266,
    SDL_SCANCODE_COMPUTER = 267,
    SDL_SCANCODE_AC_SEARCH = 268,
    SDL_SCANCODE_AC_HOME = 269,
    SDL_SCANCODE_AC_BACK = 270,
    SDL_SCANCODE_AC_FORWARD = 271,
    SDL_SCANCODE_AC_STOP = 272,
    SDL_SCANCODE_AC_REFRESH = 273,
    SDL_SCANCODE_AC_BOOKMARKS = 274,
    SDL_SCANCODE_BRIGHTNESSDOWN = 275,
    SDL_SCANCODE_BRIGHTNESSUP = 276,
    SDL_SCANCODE_DISPLAYSWITCH = 277,
    SDL_SCANCODE_KBDILLUMTOGGLE = 278,
    SDL_SCANCODE_KBDILLUMDOWN = 279,
    SDL_SCANCODE_KBDILLUMUP = 280,
    SDL_SCANCODE_EJECT = 281,
    SDL_SCANCODE_SLEEP = 282,
    SDL_SCANCODE_APP1 = 283,
    SDL_SCANCODE_APP2 = 284,
    SDL_NUM_SCANCODES = 512
} SDL_Scancode;
typedef Sint32 SDL_Keycode;
enum
{
    SDLK_UNKNOWN = 0,
    SDLK_RETURN = '\r',
    SDLK_ESCAPE = '\033',
    SDLK_BACKSPACE = '\b',
    SDLK_TAB = '\t',
    SDLK_SPACE = ' ',
    SDLK_EXCLAIM = '!',
    SDLK_QUOTEDBL = '"',
    SDLK_HASH = '#',
    SDLK_PERCENT = '%',
    SDLK_DOLLAR = '$',
    SDLK_AMPERSAND = '&',
    SDLK_QUOTE = '\'',
    SDLK_LEFTPAREN = '(',
    SDLK_RIGHTPAREN = ')',
    SDLK_ASTERISK = '*',
    SDLK_PLUS = '+',
    SDLK_COMMA = ',',
    SDLK_MINUS = '-',
    SDLK_PERIOD = '.',
    SDLK_SLASH = '/',
    SDLK_0 = '0',
    SDLK_1 = '1',
    SDLK_2 = '2',
    SDLK_3 = '3',
    SDLK_4 = '4',
    SDLK_5 = '5',
    SDLK_6 = '6',
    SDLK_7 = '7',
    SDLK_8 = '8',
    SDLK_9 = '9',
    SDLK_COLON = ':',
    SDLK_SEMICOLON = ';',
    SDLK_LESS = '<',
    SDLK_EQUALS = '=',
    SDLK_GREATER = '>',
    SDLK_QUESTION = '?',
    SDLK_AT = '@',
    SDLK_LEFTBRACKET = '\[',
    SDLK_BACKSLASH = '\\',
    SDLK_RIGHTBRACKET = '\]',
    SDLK_CARET = '^',
    SDLK_UNDERSCORE = '_',
    SDLK_BACKQUOTE = '`',
    SDLK_a = 'a',
    SDLK_b = 'b',
    SDLK_c = 'c',
    SDLK_d = 'd',
    SDLK_e = 'e',
    SDLK_f = 'f',
    SDLK_g = 'g',
    SDLK_h = 'h',
    SDLK_i = 'i',
    SDLK_j = 'j',
    SDLK_k = 'k',
    SDLK_l = 'l',
    SDLK_m = 'm',
    SDLK_n = 'n',
    SDLK_o = 'o',
    SDLK_p = 'p',
    SDLK_q = 'q',
    SDLK_r = 'r',
    SDLK_s = 's',
    SDLK_t = 't',
    SDLK_u = 'u',
    SDLK_v = 'v',
    SDLK_w = 'w',
    SDLK_x = 'x',
    SDLK_y = 'y',
    SDLK_z = 'z',
    SDLK_CAPSLOCK = (SDL_SCANCODE_CAPSLOCK | (1<<30)),
    SDLK_F1 = (SDL_SCANCODE_F1 | (1<<30)),
    SDLK_F2 = (SDL_SCANCODE_F2 | (1<<30)),
    SDLK_F3 = (SDL_SCANCODE_F3 | (1<<30)),
    SDLK_F4 = (SDL_SCANCODE_F4 | (1<<30)),
    SDLK_F5 = (SDL_SCANCODE_F5 | (1<<30)),
    SDLK_F6 = (SDL_SCANCODE_F6 | (1<<30)),
    SDLK_F7 = (SDL_SCANCODE_F7 | (1<<30)),
    SDLK_F8 = (SDL_SCANCODE_F8 | (1<<30)),
    SDLK_F9 = (SDL_SCANCODE_F9 | (1<<30)),
    SDLK_F10 = (SDL_SCANCODE_F10 | (1<<30)),
    SDLK_F11 = (SDL_SCANCODE_F11 | (1<<30)),
    SDLK_F12 = (SDL_SCANCODE_F12 | (1<<30)),
    SDLK_PRINTSCREEN = (SDL_SCANCODE_PRINTSCREEN | (1<<30)),
    SDLK_SCROLLLOCK = (SDL_SCANCODE_SCROLLLOCK | (1<<30)),
    SDLK_PAUSE = (SDL_SCANCODE_PAUSE | (1<<30)),
    SDLK_INSERT = (SDL_SCANCODE_INSERT | (1<<30)),
    SDLK_HOME = (SDL_SCANCODE_HOME | (1<<30)),
    SDLK_PAGEUP = (SDL_SCANCODE_PAGEUP | (1<<30)),
    SDLK_DELETE = '\177',
    SDLK_END = (SDL_SCANCODE_END | (1<<30)),
    SDLK_PAGEDOWN = (SDL_SCANCODE_PAGEDOWN | (1<<30)),
    SDLK_RIGHT = (SDL_SCANCODE_RIGHT | (1<<30)),
    SDLK_LEFT = (SDL_SCANCODE_LEFT | (1<<30)),
    SDLK_DOWN = (SDL_SCANCODE_DOWN | (1<<30)),
    SDLK_UP = (SDL_SCANCODE_UP | (1<<30)),
    SDLK_NUMLOCKCLEAR = (SDL_SCANCODE_NUMLOCKCLEAR | (1<<30)),
    SDLK_KP_DIVIDE = (SDL_SCANCODE_KP_DIVIDE | (1<<30)),
    SDLK_KP_MULTIPLY = (SDL_SCANCODE_KP_MULTIPLY | (1<<30)),
    SDLK_KP_MINUS = (SDL_SCANCODE_KP_MINUS | (1<<30)),
    SDLK_KP_PLUS = (SDL_SCANCODE_KP_PLUS | (1<<30)),
    SDLK_KP_ENTER = (SDL_SCANCODE_KP_ENTER | (1<<30)),
    SDLK_KP_1 = (SDL_SCANCODE_KP_1 | (1<<30)),
    SDLK_KP_2 = (SDL_SCANCODE_KP_2 | (1<<30)),
    SDLK_KP_3 = (SDL_SCANCODE_KP_3 | (1<<30)),
    SDLK_KP_4 = (SDL_SCANCODE_KP_4 | (1<<30)),
    SDLK_KP_5 = (SDL_SCANCODE_KP_5 | (1<<30)),
    SDLK_KP_6 = (SDL_SCANCODE_KP_6 | (1<<30)),
    SDLK_KP_7 = (SDL_SCANCODE_KP_7 | (1<<30)),
    SDLK_KP_8 = (SDL_SCANCODE_KP_8 | (1<<30)),
    SDLK_KP_9 = (SDL_SCANCODE_KP_9 | (1<<30)),
    SDLK_KP_0 = (SDL_SCANCODE_KP_0 | (1<<30)),
    SDLK_KP_PERIOD = (SDL_SCANCODE_KP_PERIOD | (1<<30)),
    SDLK_APPLICATION = (SDL_SCANCODE_APPLICATION | (1<<30)),
    SDLK_POWER = (SDL_SCANCODE_POWER | (1<<30)),
    SDLK_KP_EQUALS = (SDL_SCANCODE_KP_EQUALS | (1<<30)),
    SDLK_F13 = (SDL_SCANCODE_F13 | (1<<30)),
    SDLK_F14 = (SDL_SCANCODE_F14 | (1<<30)),
    SDLK_F15 = (SDL_SCANCODE_F15 | (1<<30)),
    SDLK_F16 = (SDL_SCANCODE_F16 | (1<<30)),
    SDLK_F17 = (SDL_SCANCODE_F17 | (1<<30)),
    SDLK_F18 = (SDL_SCANCODE_F18 | (1<<30)),
    SDLK_F19 = (SDL_SCANCODE_F19 | (1<<30)),
    SDLK_F20 = (SDL_SCANCODE_F20 | (1<<30)),
    SDLK_F21 = (SDL_SCANCODE_F21 | (1<<30)),
    SDLK_F22 = (SDL_SCANCODE_F22 | (1<<30)),
    SDLK_F23 = (SDL_SCANCODE_F23 | (1<<30)),
    SDLK_F24 = (SDL_SCANCODE_F24 | (1<<30)),
    SDLK_EXECUTE = (SDL_SCANCODE_EXECUTE | (1<<30)),
    SDLK_HELP = (SDL_SCANCODE_HELP | (1<<30)),
    SDLK_MENU = (SDL_SCANCODE_MENU | (1<<30)),
    SDLK_SELECT = (SDL_SCANCODE_SELECT | (1<<30)),
    SDLK_STOP = (SDL_SCANCODE_STOP | (1<<30)),
    SDLK_AGAIN = (SDL_SCANCODE_AGAIN | (1<<30)),
    SDLK_UNDO = (SDL_SCANCODE_UNDO | (1<<30)),
    SDLK_CUT = (SDL_SCANCODE_CUT | (1<<30)),
    SDLK_COPY = (SDL_SCANCODE_COPY | (1<<30)),
    SDLK_PASTE = (SDL_SCANCODE_PASTE | (1<<30)),
    SDLK_FIND = (SDL_SCANCODE_FIND | (1<<30)),
    SDLK_MUTE = (SDL_SCANCODE_MUTE | (1<<30)),
    SDLK_VOLUMEUP = (SDL_SCANCODE_VOLUMEUP | (1<<30)),
    SDLK_VOLUMEDOWN = (SDL_SCANCODE_VOLUMEDOWN | (1<<30)),
    SDLK_KP_COMMA = (SDL_SCANCODE_KP_COMMA | (1<<30)),
    SDLK_KP_EQUALSAS400 =
        (SDL_SCANCODE_KP_EQUALSAS400 | (1<<30)),
    SDLK_ALTERASE = (SDL_SCANCODE_ALTERASE | (1<<30)),
    SDLK_SYSREQ = (SDL_SCANCODE_SYSREQ | (1<<30)),
    SDLK_CANCEL = (SDL_SCANCODE_CANCEL | (1<<30)),
    SDLK_CLEAR = (SDL_SCANCODE_CLEAR | (1<<30)),
    SDLK_PRIOR = (SDL_SCANCODE_PRIOR | (1<<30)),
    SDLK_RETURN2 = (SDL_SCANCODE_RETURN2 | (1<<30)),
    SDLK_SEPARATOR = (SDL_SCANCODE_SEPARATOR | (1<<30)),
    SDLK_OUT = (SDL_SCANCODE_OUT | (1<<30)),
    SDLK_OPER = (SDL_SCANCODE_OPER | (1<<30)),
    SDLK_CLEARAGAIN = (SDL_SCANCODE_CLEARAGAIN | (1<<30)),
    SDLK_CRSEL = (SDL_SCANCODE_CRSEL | (1<<30)),
    SDLK_EXSEL = (SDL_SCANCODE_EXSEL | (1<<30)),
    SDLK_KP_00 = (SDL_SCANCODE_KP_00 | (1<<30)),
    SDLK_KP_000 = (SDL_SCANCODE_KP_000 | (1<<30)),
    SDLK_THOUSANDSSEPARATOR =
        (SDL_SCANCODE_THOUSANDSSEPARATOR | (1<<30)),
    SDLK_DECIMALSEPARATOR =
        (SDL_SCANCODE_DECIMALSEPARATOR | (1<<30)),
    SDLK_CURRENCYUNIT = (SDL_SCANCODE_CURRENCYUNIT | (1<<30)),
    SDLK_CURRENCYSUBUNIT =
        (SDL_SCANCODE_CURRENCYSUBUNIT | (1<<30)),
    SDLK_KP_LEFTPAREN = (SDL_SCANCODE_KP_LEFTPAREN | (1<<30)),
    SDLK_KP_RIGHTPAREN = (SDL_SCANCODE_KP_RIGHTPAREN | (1<<30)),
    SDLK_KP_LEFTBRACE = (SDL_SCANCODE_KP_LEFTBRACE | (1<<30)),
    SDLK_KP_RIGHTBRACE = (SDL_SCANCODE_KP_RIGHTBRACE | (1<<30)),
    SDLK_KP_TAB = (SDL_SCANCODE_KP_TAB | (1<<30)),
    SDLK_KP_BACKSPACE = (SDL_SCANCODE_KP_BACKSPACE | (1<<30)),
    SDLK_KP_A = (SDL_SCANCODE_KP_A | (1<<30)),
    SDLK_KP_B = (SDL_SCANCODE_KP_B | (1<<30)),
    SDLK_KP_C = (SDL_SCANCODE_KP_C | (1<<30)),
    SDLK_KP_D = (SDL_SCANCODE_KP_D | (1<<30)),
    SDLK_KP_E = (SDL_SCANCODE_KP_E | (1<<30)),
    SDLK_KP_F = (SDL_SCANCODE_KP_F | (1<<30)),
    SDLK_KP_XOR = (SDL_SCANCODE_KP_XOR | (1<<30)),
    SDLK_KP_POWER = (SDL_SCANCODE_KP_POWER | (1<<30)),
    SDLK_KP_PERCENT = (SDL_SCANCODE_KP_PERCENT | (1<<30)),
    SDLK_KP_LESS = (SDL_SCANCODE_KP_LESS | (1<<30)),
    SDLK_KP_GREATER = (SDL_SCANCODE_KP_GREATER | (1<<30)),
    SDLK_KP_AMPERSAND = (SDL_SCANCODE_KP_AMPERSAND | (1<<30)),
    SDLK_KP_DBLAMPERSAND =
        (SDL_SCANCODE_KP_DBLAMPERSAND | (1<<30)),
    SDLK_KP_VERTICALBAR =
        (SDL_SCANCODE_KP_VERTICALBAR | (1<<30)),
    SDLK_KP_DBLVERTICALBAR =
        (SDL_SCANCODE_KP_DBLVERTICALBAR | (1<<30)),
    SDLK_KP_COLON = (SDL_SCANCODE_KP_COLON | (1<<30)),
    SDLK_KP_HASH = (SDL_SCANCODE_KP_HASH | (1<<30)),
    SDLK_KP_SPACE = (SDL_SCANCODE_KP_SPACE | (1<<30)),
    SDLK_KP_AT = (SDL_SCANCODE_KP_AT | (1<<30)),
    SDLK_KP_EXCLAM = (SDL_SCANCODE_KP_EXCLAM | (1<<30)),
    SDLK_KP_MEMSTORE = (SDL_SCANCODE_KP_MEMSTORE | (1<<30)),
    SDLK_KP_MEMRECALL = (SDL_SCANCODE_KP_MEMRECALL | (1<<30)),
    SDLK_KP_MEMCLEAR = (SDL_SCANCODE_KP_MEMCLEAR | (1<<30)),
    SDLK_KP_MEMADD = (SDL_SCANCODE_KP_MEMADD | (1<<30)),
    SDLK_KP_MEMSUBTRACT =
        (SDL_SCANCODE_KP_MEMSUBTRACT | (1<<30)),
    SDLK_KP_MEMMULTIPLY =
        (SDL_SCANCODE_KP_MEMMULTIPLY | (1<<30)),
    SDLK_KP_MEMDIVIDE = (SDL_SCANCODE_KP_MEMDIVIDE | (1<<30)),
    SDLK_KP_PLUSMINUS = (SDL_SCANCODE_KP_PLUSMINUS | (1<<30)),
    SDLK_KP_CLEAR = (SDL_SCANCODE_KP_CLEAR | (1<<30)),
    SDLK_KP_CLEARENTRY = (SDL_SCANCODE_KP_CLEARENTRY | (1<<30)),
    SDLK_KP_BINARY = (SDL_SCANCODE_KP_BINARY | (1<<30)),
    SDLK_KP_OCTAL = (SDL_SCANCODE_KP_OCTAL | (1<<30)),
    SDLK_KP_DECIMAL = (SDL_SCANCODE_KP_DECIMAL | (1<<30)),
    SDLK_KP_HEXADECIMAL =
        (SDL_SCANCODE_KP_HEXADECIMAL | (1<<30)),
    SDLK_LCTRL = (SDL_SCANCODE_LCTRL | (1<<30)),
    SDLK_LSHIFT = (SDL_SCANCODE_LSHIFT | (1<<30)),
    SDLK_LALT = (SDL_SCANCODE_LALT | (1<<30)),
    SDLK_LGUI = (SDL_SCANCODE_LGUI | (1<<30)),
    SDLK_RCTRL = (SDL_SCANCODE_RCTRL | (1<<30)),
    SDLK_RSHIFT = (SDL_SCANCODE_RSHIFT | (1<<30)),
    SDLK_RALT = (SDL_SCANCODE_RALT | (1<<30)),
    SDLK_RGUI = (SDL_SCANCODE_RGUI | (1<<30)),
    SDLK_MODE = (SDL_SCANCODE_MODE | (1<<30)),
    SDLK_AUDIONEXT = (SDL_SCANCODE_AUDIONEXT | (1<<30)),
    SDLK_AUDIOPREV = (SDL_SCANCODE_AUDIOPREV | (1<<30)),
    SDLK_AUDIOSTOP = (SDL_SCANCODE_AUDIOSTOP | (1<<30)),
    SDLK_AUDIOPLAY = (SDL_SCANCODE_AUDIOPLAY | (1<<30)),
    SDLK_AUDIOMUTE = (SDL_SCANCODE_AUDIOMUTE | (1<<30)),
    SDLK_MEDIASELECT = (SDL_SCANCODE_MEDIASELECT | (1<<30)),
    SDLK_WWW = (SDL_SCANCODE_WWW | (1<<30)),
    SDLK_MAIL = (SDL_SCANCODE_MAIL | (1<<30)),
    SDLK_CALCULATOR = (SDL_SCANCODE_CALCULATOR | (1<<30)),
    SDLK_COMPUTER = (SDL_SCANCODE_COMPUTER | (1<<30)),
    SDLK_AC_SEARCH = (SDL_SCANCODE_AC_SEARCH | (1<<30)),
    SDLK_AC_HOME = (SDL_SCANCODE_AC_HOME | (1<<30)),
    SDLK_AC_BACK = (SDL_SCANCODE_AC_BACK | (1<<30)),
    SDLK_AC_FORWARD = (SDL_SCANCODE_AC_FORWARD | (1<<30)),
    SDLK_AC_STOP = (SDL_SCANCODE_AC_STOP | (1<<30)),
    SDLK_AC_REFRESH = (SDL_SCANCODE_AC_REFRESH | (1<<30)),
    SDLK_AC_BOOKMARKS = (SDL_SCANCODE_AC_BOOKMARKS | (1<<30)),
    SDLK_BRIGHTNESSDOWN =
        (SDL_SCANCODE_BRIGHTNESSDOWN | (1<<30)),
    SDLK_BRIGHTNESSUP = (SDL_SCANCODE_BRIGHTNESSUP | (1<<30)),
    SDLK_DISPLAYSWITCH = (SDL_SCANCODE_DISPLAYSWITCH | (1<<30)),
    SDLK_KBDILLUMTOGGLE =
        (SDL_SCANCODE_KBDILLUMTOGGLE | (1<<30)),
    SDLK_KBDILLUMDOWN = (SDL_SCANCODE_KBDILLUMDOWN | (1<<30)),
    SDLK_KBDILLUMUP = (SDL_SCANCODE_KBDILLUMUP | (1<<30)),
    SDLK_EJECT = (SDL_SCANCODE_EJECT | (1<<30)),
    SDLK_SLEEP = (SDL_SCANCODE_SLEEP | (1<<30))
};
typedef enum
{
    SDL_KMOD_NONE = 0x0000,
    SDL_KMOD_LSHIFT = 0x0001,
    SDL_KMOD_RSHIFT = 0x0002,
    SDL_KMOD_LCTRL = 0x0040,
    SDL_KMOD_RCTRL = 0x0080,
    SDL_KMOD_LALT = 0x0100,
    SDL_KMOD_RALT = 0x0200,
    SDL_KMOD_LGUI = 0x0400,
    SDL_KMOD_RGUI = 0x0800,
    SDL_KMOD_NUM = 0x1000,
    SDL_KMOD_CAPS = 0x2000,
    SDL_KMOD_MODE = 0x4000,
    SDL_KMOD_RESERVED = 0x8000
} SDL_Keymod;
typedef struct SDL_Keysym
{
    SDL_Scancode scancode;
    SDL_Keycode sym;
    Uint16 mod;
    Uint32 unused;
} SDL_Keysym;
SDL_Window * SDL_GetKeyboardFocus(void);
const Uint8 * SDL_GetKeyboardState(int *numkeys);
SDL_Keymod SDL_GetModState(void);
void SDL_SetModState(SDL_Keymod modstate);
SDL_Keycode SDL_GetKeyFromScancode(SDL_Scancode scancode);
SDL_Scancode SDL_GetScancodeFromKey(SDL_Keycode key);
const char * SDL_GetScancodeName(SDL_Scancode scancode);
SDL_Scancode SDL_GetScancodeFromName(const char *name);
const char * SDL_GetKeyName(SDL_Keycode key);
SDL_Keycode SDL_GetKeyFromName(const char *name);
void SDL_StartTextInput(void);
SDL_bool SDL_IsTextInputActive(void);
void SDL_StopTextInput(void);
void SDL_SetTextInputRect(SDL_Rect *rect);
SDL_bool SDL_HasScreenKeyboardSupport(void);
SDL_bool SDL_IsScreenKeyboardShown(SDL_Window *window);
typedef struct SDL_Cursor SDL_Cursor;
typedef enum
{
    SDL_SYSTEM_CURSOR_ARROW,
    SDL_SYSTEM_CURSOR_IBEAM,
    SDL_SYSTEM_CURSOR_WAIT,
    SDL_SYSTEM_CURSOR_CROSSHAIR,
    SDL_SYSTEM_CURSOR_WAITARROW,
    SDL_SYSTEM_CURSOR_SIZENWSE,
    SDL_SYSTEM_CURSOR_SIZENESW,
    SDL_SYSTEM_CURSOR_SIZEWE,
    SDL_SYSTEM_CURSOR_SIZENS,
    SDL_SYSTEM_CURSOR_SIZEALL,
    SDL_SYSTEM_CURSOR_NO,
    SDL_SYSTEM_CURSOR_HAND,
    SDL_NUM_SYSTEM_CURSORS
} SDL_SystemCursor;
SDL_Window * SDL_GetMouseFocus(void);
Uint32 SDL_GetMouseState(int *x, int *y);
Uint32 SDL_GetRelativeMouseState(int *x, int *y);
void SDL_WarpMouseInWindow(SDL_Window * window,
                                                   int x, int y);
int SDL_SetRelativeMouseMode(SDL_bool enabled);
SDL_bool SDL_GetRelativeMouseMode(void);
SDL_Cursor * SDL_CreateCursor(const Uint8 * data,
                                                     const Uint8 * mask,
                                                     int w, int h, int hot_x,
                                                     int hot_y);
SDL_Cursor * SDL_CreateColorCursor(SDL_Surface *surface,
                                                          int hot_x,
                                                          int hot_y);
SDL_Cursor * SDL_CreateSystemCursor(SDL_SystemCursor id);
void SDL_SetCursor(SDL_Cursor * cursor);
SDL_Cursor * SDL_GetCursor(void);
SDL_Cursor * SDL_GetDefaultCursor(void);
void SDL_FreeCursor(SDL_Cursor * cursor);
int SDL_ShowCursor(int toggle);
struct _SDL_Joystick;
typedef struct _SDL_Joystick SDL_Joystick;
typedef struct {
    Uint8 data\[16\];
} SDL_JoystickGUID;
typedef Sint32 SDL_JoystickID;
int SDL_NumJoysticks(void);
const char * SDL_JoystickNameForIndex(int device_index);
SDL_Joystick * SDL_JoystickOpen(int device_index);
const char * SDL_JoystickName(SDL_Joystick * joystick);
SDL_JoystickGUID SDL_JoystickGetDeviceGUID(int device_index);
SDL_JoystickGUID SDL_JoystickGetGUID(SDL_Joystick * joystick);
void SDL_JoystickGetGUIDString(SDL_JoystickGUID guid, char *pszGUID, int cbGUID);
SDL_JoystickGUID SDL_JoystickGetGUIDFromString(const char *pchGUID);
SDL_bool SDL_JoystickGetAttached(SDL_Joystick * joystick);
SDL_JoystickID SDL_JoystickInstanceID(SDL_Joystick * joystick);
int SDL_JoystickNumAxes(SDL_Joystick * joystick);
int SDL_JoystickNumBalls(SDL_Joystick * joystick);
int SDL_JoystickNumHats(SDL_Joystick * joystick);
int SDL_JoystickNumButtons(SDL_Joystick * joystick);
void SDL_JoystickUpdate(void);
int SDL_JoystickEventState(int state);
Sint16 SDL_JoystickGetAxis(SDL_Joystick * joystick,
                                                   int axis);
Uint8 SDL_JoystickGetHat(SDL_Joystick * joystick,
                                                 int hat);
int SDL_JoystickGetBall(SDL_Joystick * joystick,
                                                int ball, int *dx, int *dy);
Uint8 SDL_JoystickGetButton(SDL_Joystick * joystick,
                                                    int button);
void SDL_JoystickClose(SDL_Joystick * joystick);
struct _SDL_GameController;
typedef struct _SDL_GameController SDL_GameController;
typedef enum
{
    SDL_CONTROLLER_BINDTYPE_NONE = 0,
    SDL_CONTROLLER_BINDTYPE_BUTTON,
    SDL_CONTROLLER_BINDTYPE_AXIS,
    SDL_CONTROLLER_BINDTYPE_HAT
} SDL_GameControllerBindType;
typedef struct SDL_GameControllerButtonBind
{
    SDL_GameControllerBindType bindType;
    union
    {
        int button;
        int axis;
        struct {
            int hat;
            int hat_mask;
        } hat;
    } value;
} SDL_GameControllerButtonBind;
int SDL_GameControllerAddMapping( const char* mappingString );
char * SDL_GameControllerMappingForGUID( SDL_JoystickGUID guid );
char * SDL_GameControllerMapping( SDL_GameController * gamecontroller );
SDL_bool SDL_IsGameController(int joystick_index);
const char * SDL_GameControllerNameForIndex(int joystick_index);
SDL_GameController * SDL_GameControllerOpen(int joystick_index);
const char * SDL_GameControllerName(SDL_GameController *gamecontroller);
SDL_bool SDL_GameControllerGetAttached(SDL_GameController *gamecontroller);
SDL_Joystick * SDL_GameControllerGetJoystick(SDL_GameController *gamecontroller);
int SDL_GameControllerEventState(int state);
void SDL_GameControllerUpdate(void);
typedef enum
{
    SDL_CONTROLLER_AXIS_INVALID = -1,
    SDL_CONTROLLER_AXIS_LEFTX,
    SDL_CONTROLLER_AXIS_LEFTY,
    SDL_CONTROLLER_AXIS_RIGHTX,
    SDL_CONTROLLER_AXIS_RIGHTY,
    SDL_CONTROLLER_AXIS_TRIGGERLEFT,
    SDL_CONTROLLER_AXIS_TRIGGERRIGHT,
    SDL_CONTROLLER_AXIS_MAX
} SDL_GameControllerAxis;
SDL_GameControllerAxis SDL_GameControllerGetAxisFromString(const char *pchString);
const char* SDL_GameControllerGetStringForAxis(SDL_GameControllerAxis axis);
SDL_GameControllerButtonBind
SDL_GameControllerGetBindForAxis(SDL_GameController *gamecontroller,
                                 SDL_GameControllerAxis axis);
Sint16
SDL_GameControllerGetAxis(SDL_GameController *gamecontroller,
                          SDL_GameControllerAxis axis);
typedef enum
{
    SDL_CONTROLLER_BUTTON_INVALID = -1,
    SDL_CONTROLLER_BUTTON_A,
    SDL_CONTROLLER_BUTTON_B,
    SDL_CONTROLLER_BUTTON_X,
    SDL_CONTROLLER_BUTTON_Y,
    SDL_CONTROLLER_BUTTON_BACK,
    SDL_CONTROLLER_BUTTON_GUIDE,
    SDL_CONTROLLER_BUTTON_START,
    SDL_CONTROLLER_BUTTON_LEFTSTICK,
    SDL_CONTROLLER_BUTTON_RIGHTSTICK,
    SDL_CONTROLLER_BUTTON_LEFTSHOULDER,
    SDL_CONTROLLER_BUTTON_RIGHTSHOULDER,
    SDL_CONTROLLER_BUTTON_DPAD_UP,
    SDL_CONTROLLER_BUTTON_DPAD_DOWN,
    SDL_CONTROLLER_BUTTON_DPAD_LEFT,
    SDL_CONTROLLER_BUTTON_DPAD_RIGHT,
    SDL_CONTROLLER_BUTTON_MAX
} SDL_GameControllerButton;
SDL_GameControllerButton SDL_GameControllerGetButtonFromString(const char *pchString);
const char* SDL_GameControllerGetStringForButton(SDL_GameControllerButton button);
SDL_GameControllerButtonBind
SDL_GameControllerGetBindForButton(SDL_GameController *gamecontroller,
                                   SDL_GameControllerButton button);
Uint8 SDL_GameControllerGetButton(SDL_GameController *gamecontroller,
                                                          SDL_GameControllerButton button);
void SDL_GameControllerClose(SDL_GameController *gamecontroller);
typedef Sint64 SDL_TouchID;
typedef Sint64 SDL_FingerID;
typedef struct SDL_Finger
{
    SDL_FingerID id;
    float x;
    float y;
    float pressure;
} SDL_Finger;
int SDL_GetNumTouchDevices(void);
SDL_TouchID SDL_GetTouchDevice(int index);
int SDL_GetNumTouchFingers(SDL_TouchID touchID);
SDL_Finger * SDL_GetTouchFinger(SDL_TouchID touchID, int index);
typedef Sint64 SDL_GestureID;
int SDL_RecordGesture(SDL_TouchID touchId);
int SDL_SaveAllDollarTemplates(SDL_RWops *src);
int SDL_SaveDollarTemplate(SDL_GestureID gestureId,SDL_RWops *src);
int SDL_LoadDollarTemplates(SDL_TouchID touchId, SDL_RWops *src);
typedef enum
{
    SDL_FIRSTEVENT = 0,
    SDL_QUIT = 0x100,
    SDL_APP_TERMINATING,
    SDL_APP_LOWMEMORY,
    SDL_APP_WILLENTERBACKGROUND,
    SDL_APP_DIDENTERBACKGROUND,
    SDL_APP_WILLENTERFOREGROUND,
    SDL_APP_DIDENTERFOREGROUND,
    SDL_WINDOWEVENT = 0x200,
    SDL_SYSWMEVENT,
    SDL_KEYDOWN = 0x300,
    SDL_KEYUP,
    SDL_TEXTEDITING,
    SDL_TEXTINPUT,
    SDL_MOUSEMOTION = 0x400,
    SDL_MOUSEBUTTONDOWN,
    SDL_MOUSEBUTTONUP,
    SDL_MOUSEWHEEL,
    SDL_JOYAXISMOTION = 0x600,
    SDL_JOYBALLMOTION,
    SDL_JOYHATMOTION,
    SDL_JOYBUTTONDOWN,
    SDL_JOYBUTTONUP,
    SDL_JOYDEVICEADDED,
    SDL_JOYDEVICEREMOVED,
    SDL_CONTROLLERAXISMOTION = 0x650,
    SDL_CONTROLLERBUTTONDOWN,
    SDL_CONTROLLERBUTTONUP,
    SDL_CONTROLLERDEVICEADDED,
    SDL_CONTROLLERDEVICEREMOVED,
    SDL_CONTROLLERDEVICEREMAPPED,
    SDL_FINGERDOWN = 0x700,
    SDL_FINGERUP,
    SDL_FINGERMOTION,
    SDL_DOLLARGESTURE = 0x800,
    SDL_DOLLARRECORD,
    SDL_MULTIGESTURE,
    SDL_CLIPBOARDUPDATE = 0x900,
    SDL_DROPFILE = 0x1000,
    SDL_USEREVENT = 0x8000,
    SDL_LASTEVENT = 0xFFFF
} SDL_EventType;
typedef struct SDL_CommonEvent
{
    Uint32 type;
    Uint32 timestamp;
} SDL_CommonEvent;
typedef struct SDL_WindowEvent
{
    Uint32 type;
    Uint32 timestamp;
    Uint32 windowID;
    Uint8 event;
    Uint8 padding1;
    Uint8 padding2;
    Uint8 padding3;
    Sint32 data1;
    Sint32 data2;
} SDL_WindowEvent;
typedef struct SDL_KeyboardEvent
{
    Uint32 type;
    Uint32 timestamp;
    Uint32 windowID;
    Uint8 state;
    Uint8 repeat;
    Uint8 padding2;
    Uint8 padding3;
    SDL_Keysym keysym;
} SDL_KeyboardEvent;
typedef struct SDL_TextEditingEvent
{
    Uint32 type;
    Uint32 timestamp;
    Uint32 windowID;
    char text\[(32)\];
    Sint32 start;
    Sint32 length;
} SDL_TextEditingEvent;
typedef struct SDL_TextInputEvent
{
    Uint32 type;
    Uint32 timestamp;
    Uint32 windowID;
    char text\[(32)\];
} SDL_TextInputEvent;
typedef struct SDL_MouseMotionEvent
{
    Uint32 type;
    Uint32 timestamp;
    Uint32 windowID;
    Uint32 which;
    Uint32 state;
    Sint32 x;
    Sint32 y;
    Sint32 xrel;
    Sint32 yrel;
} SDL_MouseMotionEvent;
typedef struct SDL_MouseButtonEvent
{
    Uint32 type;
    Uint32 timestamp;
    Uint32 windowID;
    Uint32 which;
    Uint8 button;
    Uint8 state;
    Uint8 padding1;
    Uint8 padding2;
    Sint32 x;
    Sint32 y;
} SDL_MouseButtonEvent;
typedef struct SDL_MouseWheelEvent
{
    Uint32 type;
    Uint32 timestamp;
    Uint32 windowID;
    Uint32 which;
    Sint32 x;
    Sint32 y;
} SDL_MouseWheelEvent;
typedef struct SDL_JoyAxisEvent
{
    Uint32 type;
    Uint32 timestamp;
    SDL_JoystickID which;
    Uint8 axis;
    Uint8 padding1;
    Uint8 padding2;
    Uint8 padding3;
    Sint16 value;
    Uint16 padding4;
} SDL_JoyAxisEvent;
typedef struct SDL_JoyBallEvent
{
    Uint32 type;
    Uint32 timestamp;
    SDL_JoystickID which;
    Uint8 ball;
    Uint8 padding1;
    Uint8 padding2;
    Uint8 padding3;
    Sint16 xrel;
    Sint16 yrel;
} SDL_JoyBallEvent;
typedef struct SDL_JoyHatEvent
{
    Uint32 type;
    Uint32 timestamp;
    SDL_JoystickID which;
    Uint8 hat;
    Uint8 value;
    Uint8 padding1;
    Uint8 padding2;
} SDL_JoyHatEvent;
typedef struct SDL_JoyButtonEvent
{
    Uint32 type;
    Uint32 timestamp;
    SDL_JoystickID which;
    Uint8 button;
    Uint8 state;
    Uint8 padding1;
    Uint8 padding2;
} SDL_JoyButtonEvent;
typedef struct SDL_JoyDeviceEvent
{
    Uint32 type;
    Uint32 timestamp;
    Sint32 which;
} SDL_JoyDeviceEvent;
typedef struct SDL_ControllerAxisEvent
{
    Uint32 type;
    Uint32 timestamp;
    SDL_JoystickID which;
    Uint8 axis;
    Uint8 padding1;
    Uint8 padding2;
    Uint8 padding3;
    Sint16 value;
    Uint16 padding4;
} SDL_ControllerAxisEvent;
typedef struct SDL_ControllerButtonEvent
{
    Uint32 type;
    Uint32 timestamp;
    SDL_JoystickID which;
    Uint8 button;
    Uint8 state;
    Uint8 padding1;
    Uint8 padding2;
} SDL_ControllerButtonEvent;
typedef struct SDL_ControllerDeviceEvent
{
    Uint32 type;
    Uint32 timestamp;
    Sint32 which;
} SDL_ControllerDeviceEvent;
typedef struct SDL_TouchFingerEvent
{
    Uint32 type;
    Uint32 timestamp;
    SDL_TouchID touchId;
    SDL_FingerID fingerId;
    float x;
    float y;
    float dx;
    float dy;
    float pressure;
} SDL_TouchFingerEvent;
typedef struct SDL_MultiGestureEvent
{
    Uint32 type;
    Uint32 timestamp;
    SDL_TouchID touchId;
    float dTheta;
    float dDist;
    float x;
    float y;
    Uint16 numFingers;
    Uint16 padding;
} SDL_MultiGestureEvent;
typedef struct SDL_DollarGestureEvent
{
    Uint32 type;
    Uint32 timestamp;
    SDL_TouchID touchId;
    SDL_GestureID gestureId;
    Uint32 numFingers;
    float error;
    float x;
    float y;
} SDL_DollarGestureEvent;
typedef struct SDL_DropEvent
{
    Uint32 type;
    Uint32 timestamp;
    char *file;
} SDL_DropEvent;
typedef struct SDL_QuitEvent
{
    Uint32 type;
    Uint32 timestamp;
} SDL_QuitEvent;
typedef struct SDL_OSEvent
{
    Uint32 type;
    Uint32 timestamp;
} SDL_OSEvent;
typedef struct SDL_UserEvent
{
    Uint32 type;
    Uint32 timestamp;
    Uint32 windowID;
    Sint32 code;
    void *data1;
    void *data2;
} SDL_UserEvent;
struct SDL_SysWMmsg;
typedef struct SDL_SysWMmsg SDL_SysWMmsg;
typedef struct SDL_SysWMEvent
{
    Uint32 type;
    Uint32 timestamp;
    SDL_SysWMmsg *msg;
} SDL_SysWMEvent;
typedef union SDL_Event
{
    Uint32 type;
    SDL_CommonEvent common;
    SDL_WindowEvent window;
    SDL_KeyboardEvent key;
    SDL_TextEditingEvent edit;
    SDL_TextInputEvent text;
    SDL_MouseMotionEvent motion;
    SDL_MouseButtonEvent button;
    SDL_MouseWheelEvent wheel;
    SDL_JoyAxisEvent jaxis;
    SDL_JoyBallEvent jball;
    SDL_JoyHatEvent jhat;
    SDL_JoyButtonEvent jbutton;
    SDL_JoyDeviceEvent jdevice;
    SDL_ControllerAxisEvent caxis;
    SDL_ControllerButtonEvent cbutton;
    SDL_ControllerDeviceEvent cdevice;
    SDL_QuitEvent quit;
    SDL_UserEvent user;
    SDL_SysWMEvent syswm;
    SDL_TouchFingerEvent tfinger;
    SDL_MultiGestureEvent mgesture;
    SDL_DollarGestureEvent dgesture;
    SDL_DropEvent drop;
    Uint8 padding\[56\];
} SDL_Event;
void SDL_PumpEvents(void);
typedef enum
{
    SDL_ADDEVENT,
    SDL_PEEKEVENT,
    SDL_GETEVENT
} SDL_eventaction;
int SDL_PeepEvents(SDL_Event * events, int numevents,
                                           SDL_eventaction action,
                                           Uint32 minType, Uint32 maxType);
SDL_bool SDL_HasEvent(Uint32 type);
SDL_bool SDL_HasEvents(Uint32 minType, Uint32 maxType);
void SDL_FlushEvent(Uint32 type);
void SDL_FlushEvents(Uint32 minType, Uint32 maxType);
int SDL_PollEvent(SDL_Event * event);
int SDL_WaitEvent(SDL_Event * event);
int SDL_WaitEventTimeout(SDL_Event * event,
                                                 int timeout);
int SDL_PushEvent(SDL_Event * event);
typedef int ( * SDL_EventFilter) (void *userdata, SDL_Event * event);
void SDL_SetEventFilter(SDL_EventFilter filter,
                                                void *userdata);
SDL_bool SDL_GetEventFilter(SDL_EventFilter * filter,
                                                    void **userdata);
void SDL_AddEventWatch(SDL_EventFilter filter,
                                               void *userdata);
void SDL_DelEventWatch(SDL_EventFilter filter,
                                               void *userdata);
void SDL_FilterEvents(SDL_EventFilter filter,
                                              void *userdata);
Uint8 SDL_EventState(Uint32 type, int state);
Uint32 SDL_RegisterEvents(int numevents);
struct _SDL_Haptic;
typedef struct _SDL_Haptic SDL_Haptic;
typedef struct SDL_HapticDirection
{
    Uint8 type;
    Sint32 dir\[3\];
} SDL_HapticDirection;
typedef struct SDL_HapticConstant
{
    Uint16 type;
    SDL_HapticDirection direction;
    Uint32 length;
    Uint16 delay;
    Uint16 button;
    Uint16 interval;
    Sint16 level;
    Uint16 attack_length;
    Uint16 attack_level;
    Uint16 fade_length;
    Uint16 fade_level;
} SDL_HapticConstant;
typedef struct SDL_HapticPeriodic
{
    Uint16 type;
    SDL_HapticDirection direction;
    Uint32 length;
    Uint16 delay;
    Uint16 button;
    Uint16 interval;
    Uint16 period;
    Sint16 magnitude;
    Sint16 offset;
    Uint16 phase;
    Uint16 attack_length;
    Uint16 attack_level;
    Uint16 fade_length;
    Uint16 fade_level;
} SDL_HapticPeriodic;
typedef struct SDL_HapticCondition
{
    Uint16 type;
    SDL_HapticDirection direction;
    Uint32 length;
    Uint16 delay;
    Uint16 button;
    Uint16 interval;
    Uint16 right_sat\[3\];
    Uint16 left_sat\[3\];
    Sint16 right_coeff\[3\];
    Sint16 left_coeff\[3\];
    Uint16 deadband\[3\];
    Sint16 center\[3\];
} SDL_HapticCondition;
typedef struct SDL_HapticRamp
{
    Uint16 type;
    SDL_HapticDirection direction;
    Uint32 length;
    Uint16 delay;
    Uint16 button;
    Uint16 interval;
    Sint16 start;
    Sint16 end;
    Uint16 attack_length;
    Uint16 attack_level;
    Uint16 fade_length;
    Uint16 fade_level;
} SDL_HapticRamp;
typedef struct SDL_HapticLeftRight
{
    Uint16 type;
    Uint32 length;
    Uint16 large_magnitude;
    Uint16 small_magnitude;
} SDL_HapticLeftRight;
typedef struct SDL_HapticCustom
{
    Uint16 type;
    SDL_HapticDirection direction;
    Uint32 length;
    Uint16 delay;
    Uint16 button;
    Uint16 interval;
    Uint8 channels;
    Uint16 period;
    Uint16 samples;
    Uint16 *data;
    Uint16 attack_length;
    Uint16 attack_level;
    Uint16 fade_length;
    Uint16 fade_level;
} SDL_HapticCustom;
typedef union SDL_HapticEffect
{
    Uint16 type;
    SDL_HapticConstant constant;
    SDL_HapticPeriodic periodic;
    SDL_HapticCondition condition;
    SDL_HapticRamp ramp;
    SDL_HapticLeftRight leftright;
    SDL_HapticCustom custom;
} SDL_HapticEffect;
int SDL_NumHaptics(void);
const char * SDL_HapticName(int device_index);
SDL_Haptic * SDL_HapticOpen(int device_index);
int SDL_HapticOpened(int device_index);
int SDL_HapticIndex(SDL_Haptic * haptic);
int SDL_MouseIsHaptic(void);
SDL_Haptic * SDL_HapticOpenFromMouse(void);
int SDL_JoystickIsHaptic(SDL_Joystick * joystick);
SDL_Haptic * SDL_HapticOpenFromJoystick(SDL_Joystick *
                                                               joystick);
void SDL_HapticClose(SDL_Haptic * haptic);
int SDL_HapticNumEffects(SDL_Haptic * haptic);
int SDL_HapticNumEffectsPlaying(SDL_Haptic * haptic);
unsigned int SDL_HapticQuery(SDL_Haptic * haptic);
int SDL_HapticNumAxes(SDL_Haptic * haptic);
int SDL_HapticEffectSupported(SDL_Haptic * haptic,
                                                      SDL_HapticEffect *
                                                      effect);
int SDL_HapticNewEffect(SDL_Haptic * haptic,
                                                SDL_HapticEffect * effect);
int SDL_HapticUpdateEffect(SDL_Haptic * haptic,
                                                   int effect,
                                                   SDL_HapticEffect * data);
int SDL_HapticRunEffect(SDL_Haptic * haptic,
                                                int effect,
                                                Uint32 iterations);
int SDL_HapticStopEffect(SDL_Haptic * haptic,
                                                 int effect);
void SDL_HapticDestroyEffect(SDL_Haptic * haptic,
                                                     int effect);
int SDL_HapticGetEffectStatus(SDL_Haptic * haptic,
                                                      int effect);
int SDL_HapticSetGain(SDL_Haptic * haptic, int gain);
int SDL_HapticSetAutocenter(SDL_Haptic * haptic,
                                                    int autocenter);
int SDL_HapticPause(SDL_Haptic * haptic);
int SDL_HapticUnpause(SDL_Haptic * haptic);
int SDL_HapticStopAll(SDL_Haptic * haptic);
int SDL_HapticRumbleSupported(SDL_Haptic * haptic);
int SDL_HapticRumbleInit(SDL_Haptic * haptic);
int SDL_HapticRumblePlay(SDL_Haptic * haptic, float strength, Uint32 length );
int SDL_HapticRumbleStop(SDL_Haptic * haptic);
typedef enum
{
    SDL_HINT_DEFAULT,
    SDL_HINT_NORMAL,
    SDL_HINT_OVERRIDE
} SDL_HintPriority;
SDL_bool SDL_SetHintWithPriority(const char *name,
                                                         const char *value,
                                                         SDL_HintPriority priority);
SDL_bool SDL_SetHint(const char *name,
                                             const char *value);
const char * SDL_GetHint(const char *name);
typedef void (*SDL_HintCallback)(void *userdata, const char *name, const char *oldValue, const char *newValue);
void SDL_AddHintCallback(const char *name,
                                                 SDL_HintCallback callback,
                                                 void *userdata);
void SDL_DelHintCallback(const char *name,
                                                 SDL_HintCallback callback,
                                                 void *userdata);
void SDL_ClearHints(void);
void * SDL_LoadObject(const char *sofile);
void * SDL_LoadFunction(void *handle,
                                               const char *name);
void SDL_UnloadObject(void *handle);
enum
{
    SDL_LOG_CATEGORY_APPLICATION,
    SDL_LOG_CATEGORY_ERROR,
    SDL_LOG_CATEGORY_ASSERT,
    SDL_LOG_CATEGORY_SYSTEM,
    SDL_LOG_CATEGORY_AUDIO,
    SDL_LOG_CATEGORY_VIDEO,
    SDL_LOG_CATEGORY_RENDER,
    SDL_LOG_CATEGORY_INPUT,
    SDL_LOG_CATEGORY_TEST,
    SDL_LOG_CATEGORY_RESERVED1,
    SDL_LOG_CATEGORY_RESERVED2,
    SDL_LOG_CATEGORY_RESERVED3,
    SDL_LOG_CATEGORY_RESERVED4,
    SDL_LOG_CATEGORY_RESERVED5,
    SDL_LOG_CATEGORY_RESERVED6,
    SDL_LOG_CATEGORY_RESERVED7,
    SDL_LOG_CATEGORY_RESERVED8,
    SDL_LOG_CATEGORY_RESERVED9,
    SDL_LOG_CATEGORY_RESERVED10,
    SDL_LOG_CATEGORY_CUSTOM
};
typedef enum
{
    SDL_LOG_PRIORITY_VERBOSE = 1,
    SDL_LOG_PRIORITY_DEBUG,
    SDL_LOG_PRIORITY_INFO,
    SDL_LOG_PRIORITY_WARN,
    SDL_LOG_PRIORITY_ERROR,
    SDL_LOG_PRIORITY_CRITICAL,
    SDL_NUM_LOG_PRIORITIES
} SDL_LogPriority;
void SDL_LogSetAllPriority(SDL_LogPriority priority);
void SDL_LogSetPriority(int category,
                                                SDL_LogPriority priority);
SDL_LogPriority SDL_LogGetPriority(int category);
void SDL_LogResetPriorities(void);
void SDL_Log(const char *fmt, ...);
void SDL_LogVerbose(int category, const char *fmt, ...);
void SDL_LogDebug(int category, const char *fmt, ...);
void SDL_LogInfo(int category, const char *fmt, ...);
void SDL_LogWarn(int category, const char *fmt, ...);
void SDL_LogError(int category, const char *fmt, ...);
void SDL_LogCritical(int category, const char *fmt, ...);
void SDL_LogMessage(int category,
                                            SDL_LogPriority priority,
                                            const char *fmt, ...);
void SDL_LogMessageV(int category,
                                             SDL_LogPriority priority,
                                             const char *fmt, va_list ap);
typedef void (*SDL_LogOutputFunction)(void *userdata, int category, SDL_LogPriority priority, const char *message);
void SDL_LogGetOutputFunction(SDL_LogOutputFunction *callback, void **userdata);
void SDL_LogSetOutputFunction(SDL_LogOutputFunction callback, void *userdata);
typedef enum
{
    SDL_MESSAGEBOX_ERROR = 0x00000010,
    SDL_MESSAGEBOX_WARNING = 0x00000020,
    SDL_MESSAGEBOX_INFORMATION = 0x00000040
} SDL_MessageBoxFlags;
typedef enum
{
    SDL_MESSAGEBOX_BUTTON_RETURNKEY_DEFAULT = 0x00000001,
    SDL_MESSAGEBOX_BUTTON_ESCAPEKEY_DEFAULT = 0x00000002
} SDL_MessageBoxButtonFlags;
typedef struct
{
    Uint32 flags;
    int buttonid;
    const char * text;
} SDL_MessageBoxButtonData;
typedef struct
{
    Uint8 r, g, b;
} SDL_MessageBoxColor;
typedef enum
{
    SDL_MESSAGEBOX_COLOR_BACKGROUND,
    SDL_MESSAGEBOX_COLOR_TEXT,
    SDL_MESSAGEBOX_COLOR_BUTTON_BORDER,
    SDL_MESSAGEBOX_COLOR_BUTTON_BACKGROUND,
    SDL_MESSAGEBOX_COLOR_BUTTON_SELECTED,
    SDL_MESSAGEBOX_COLOR_MAX
} SDL_MessageBoxColorType;
typedef struct
{
    SDL_MessageBoxColor colors\[SDL_MESSAGEBOX_COLOR_MAX\];
} SDL_MessageBoxColorScheme;
typedef struct
{
    Uint32 flags;
    SDL_Window *window;
    const char *title;
    const char *message;
    int numbuttons;
    const SDL_MessageBoxButtonData *buttons;
    const SDL_MessageBoxColorScheme *colorScheme;
} SDL_MessageBoxData;
int SDL_ShowMessageBox(const SDL_MessageBoxData *messageboxdata, int *buttonid);
int SDL_ShowSimpleMessageBox(Uint32 flags, const char *title, const char *message, SDL_Window *window);
typedef enum
{
    SDL_POWERSTATE_UNKNOWN,
    SDL_POWERSTATE_ON_BATTERY,
    SDL_POWERSTATE_NO_BATTERY,
    SDL_POWERSTATE_CHARGING,
    SDL_POWERSTATE_CHARGED
} SDL_PowerState;
SDL_PowerState SDL_GetPowerInfo(int *secs, int *pct);
typedef enum
{
    SDL_RENDERER_SOFTWARE = 0x00000001,
    SDL_RENDERER_ACCELERATED = 0x00000002,
    SDL_RENDERER_PRESENTVSYNC = 0x00000004,
    SDL_RENDERER_TARGETTEXTURE = 0x00000008
} SDL_RendererFlags;
typedef struct SDL_RendererInfo
{
    const char *name;
    Uint32 flags;
    Uint32 num_texture_formats;
    Uint32 texture_formats\[16\];
    int max_texture_width;
    int max_texture_height;
} SDL_RendererInfo;
typedef enum
{
    SDL_TEXTUREACCESS_STATIC,
    SDL_TEXTUREACCESS_STREAMING,
    SDL_TEXTUREACCESS_TARGET
} SDL_TextureAccess;
typedef enum
{
    SDL_TEXTUREMODULATE_NONE = 0x00000000,
    SDL_TEXTUREMODULATE_COLOR = 0x00000001,
    SDL_TEXTUREMODULATE_ALPHA = 0x00000002
} SDL_TextureModulate;
typedef enum
{
    SDL_FLIP_NONE = 0x00000000,
    SDL_FLIP_HORIZONTAL = 0x00000001,
    SDL_FLIP_VERTICAL = 0x00000002
} SDL_RendererFlip;
struct SDL_Renderer;
typedef struct SDL_Renderer SDL_Renderer;
struct SDL_Texture;
typedef struct SDL_Texture SDL_Texture;
int SDL_GetNumRenderDrivers(void);
int SDL_GetRenderDriverInfo(int index,
                                                    SDL_RendererInfo * info);
int SDL_CreateWindowAndRenderer(
                                int width, int height, Uint32 window_flags,
                                SDL_Window **window, SDL_Renderer **renderer);
SDL_Renderer * SDL_CreateRenderer(SDL_Window * window,
                                               int index, Uint32 flags);
SDL_Renderer * SDL_CreateSoftwareRenderer(SDL_Surface * surface);
SDL_Renderer * SDL_GetRenderer(SDL_Window * window);
int SDL_GetRendererInfo(SDL_Renderer * renderer,
                                                SDL_RendererInfo * info);
int SDL_GetRendererOutputSize(SDL_Renderer * renderer,
                                                      int *w, int *h);
SDL_Texture * SDL_CreateTexture(SDL_Renderer * renderer,
                                                        Uint32 format,
                                                        int access, int w,
                                                        int h);
SDL_Texture * SDL_CreateTextureFromSurface(SDL_Renderer * renderer, SDL_Surface * surface);
int SDL_QueryTexture(SDL_Texture * texture,
                                             Uint32 * format, int *access,
                                             int *w, int *h);
int SDL_SetTextureColorMod(SDL_Texture * texture,
                                                   Uint8 r, Uint8 g, Uint8 b);
int SDL_GetTextureColorMod(SDL_Texture * texture,
                                                   Uint8 * r, Uint8 * g,
                                                   Uint8 * b);
int SDL_SetTextureAlphaMod(SDL_Texture * texture,
                                                   Uint8 alpha);
int SDL_GetTextureAlphaMod(SDL_Texture * texture,
                                                   Uint8 * alpha);
int SDL_SetTextureBlendMode(SDL_Texture * texture,
                                                    SDL_BlendMode blendMode);
int SDL_GetTextureBlendMode(SDL_Texture * texture,
                                                    SDL_BlendMode *blendMode);
int SDL_UpdateTexture(SDL_Texture * texture,
                                              const SDL_Rect * rect,
                                              const void *pixels, int pitch);
int SDL_LockTexture(SDL_Texture * texture,
                                            const SDL_Rect * rect,
                                            void **pixels, int *pitch);
void SDL_UnlockTexture(SDL_Texture * texture);
SDL_bool SDL_RenderTargetSupported(SDL_Renderer *renderer);
int SDL_SetRenderTarget(SDL_Renderer *renderer,
                                                SDL_Texture *texture);
SDL_Texture * SDL_GetRenderTarget(SDL_Renderer *renderer);
int SDL_RenderSetLogicalSize(SDL_Renderer * renderer, int w, int h);
void SDL_RenderGetLogicalSize(SDL_Renderer * renderer, int *w, int *h);
int SDL_RenderSetViewport(SDL_Renderer * renderer,
                                                  const SDL_Rect * rect);
void SDL_RenderGetViewport(SDL_Renderer * renderer,
                                                   SDL_Rect * rect);
int SDL_RenderSetClipRect(SDL_Renderer * renderer,
                                                  const SDL_Rect * rect);
void SDL_RenderGetClipRect(SDL_Renderer * renderer,
                                                   SDL_Rect * rect);
int SDL_RenderSetScale(SDL_Renderer * renderer,
                                               float scaleX, float scaleY);
void SDL_RenderGetScale(SDL_Renderer * renderer,
                                               float *scaleX, float *scaleY);
int SDL_SetRenderDrawColor(SDL_Renderer * renderer,
                                           Uint8 r, Uint8 g, Uint8 b,
                                           Uint8 a);
int SDL_GetRenderDrawColor(SDL_Renderer * renderer,
                                           Uint8 * r, Uint8 * g, Uint8 * b,
                                           Uint8 * a);
int SDL_SetRenderDrawBlendMode(SDL_Renderer * renderer,
                                                       SDL_BlendMode blendMode);
int SDL_GetRenderDrawBlendMode(SDL_Renderer * renderer,
                                                       SDL_BlendMode *blendMode);
int SDL_RenderClear(SDL_Renderer * renderer);
int SDL_RenderDrawPoint(SDL_Renderer * renderer,
                                                int x, int y);
int SDL_RenderDrawPoints(SDL_Renderer * renderer,
                                                 const SDL_Point * points,
                                                 int count);
int SDL_RenderDrawLine(SDL_Renderer * renderer,
                                               int x1, int y1, int x2, int y2);
int SDL_RenderDrawLines(SDL_Renderer * renderer,
                                                const SDL_Point * points,
                                                int count);
int SDL_RenderDrawRect(SDL_Renderer * renderer,
                                               const SDL_Rect * rect);
int SDL_RenderDrawRects(SDL_Renderer * renderer,
                                                const SDL_Rect * rects,
                                                int count);
int SDL_RenderFillRect(SDL_Renderer * renderer,
                                               const SDL_Rect * rect);
int SDL_RenderFillRects(SDL_Renderer * renderer,
                                                const SDL_Rect * rects,
                                                int count);
int SDL_RenderCopy(SDL_Renderer * renderer,
                                           SDL_Texture * texture,
                                           const SDL_Rect * srcrect,
                                           const SDL_Rect * dstrect);
int SDL_RenderCopyEx(SDL_Renderer * renderer,
                                           SDL_Texture * texture,
                                           const SDL_Rect * srcrect,
                                           const SDL_Rect * dstrect,
                                           const double angle,
                                           const SDL_Point *center,
                                           const SDL_RendererFlip flip);
int SDL_RenderReadPixels(SDL_Renderer * renderer,
                                                 const SDL_Rect * rect,
                                                 Uint32 format,
                                                 void *pixels, int pitch);
void SDL_RenderPresent(SDL_Renderer * renderer);
void SDL_DestroyTexture(SDL_Texture * texture);
void SDL_DestroyRenderer(SDL_Renderer * renderer);
int SDL_GL_BindTexture(SDL_Texture *texture, float *texw, float *texh);
int SDL_GL_UnbindTexture(SDL_Texture *texture);
Uint32 SDL_GetTicks(void);
Uint64 SDL_GetPerformanceCounter(void);
Uint64 SDL_GetPerformanceFrequency(void);
void SDL_Delay(Uint32 ms);
typedef Uint32 ( * SDL_TimerCallback) (Uint32 interval, void *param);
typedef int SDL_TimerID;
SDL_TimerID SDL_AddTimer(Uint32 interval,
                                                 SDL_TimerCallback callback,
                                                 void *param);
SDL_bool SDL_RemoveTimer(SDL_TimerID id);
typedef struct SDL_version
{
    Uint8 major;
    Uint8 minor;
    Uint8 patch;
} SDL_version;
void SDL_GetVersion(SDL_version * ver);
const char * SDL_GetRevision(void);
int SDL_GetRevisionNumber(void);
int SDL_Init(Uint32 flags);
int SDL_InitSubSystem(Uint32 flags);
void SDL_QuitSubSystem(Uint32 flags);
Uint32 SDL_WasInit(Uint32 flags);
void SDL_Quit(void);

\]\]

-- sdl

ffi.cdef\[\[
enum {
SDL_INIT_TIMER          = 0x00000001,
SDL_INIT_AUDIO          = 0x00000010,
SDL_INIT_VIDEO          = 0x00000020,
SDL_INIT_JOYSTICK       = 0x00000200,
SDL_INIT_HAPTIC         = 0x00001000,
SDL_INIT_GAMECONTROLLER = 0x00002000,
SDL_INIT_EVENTS         = 0x00004000,
SDL_INIT_NOPARACHUTE    = 0x00100000,
SDL_INIT_EVERYTHING     = ( \
                SDL_INIT_TIMER | SDL_INIT_AUDIO | SDL_INIT_VIDEO | SDL_INIT_EVENTS | \
                SDL_INIT_JOYSTICK | SDL_INIT_HAPTIC | SDL_INIT_GAMECONTROLLER \
            )
};
\]\]
-- audio

ffi.cdef\[\[
enum {
SDL_AUDIO_MASK_BITSIZE       = (0xFF),
SDL_AUDIO_MASK_DATATYPE      = (1<<8),
SDL_AUDIO_MASK_ENDIAN        = (1<<12),
SDL_AUDIO_MASK_SIGNED        = (1<<15)
};

enum {
SDL_AUDIO_U8        = 0x0008,
SDL_AUDIO_S8        = 0x8008,
SDL_AUDIO_U16LSB    = 0x0010,
SDL_AUDIO_S16LSB    = 0x8010,
SDL_AUDIO_U16MSB    = 0x1010,
SDL_AUDIO_S16MSB    = 0x9010,
SDL_AUDIO_U16       = SDL_AUDIO_U16LSB,
SDL_AUDIO_S16       = SDL_AUDIO_S16LSB,

SDL_AUDIO_S32LSB    = 0x8020,
SDL_AUDIO_S32MSB    = 0x9020,
SDL_AUDIO_S32       = SDL_AUDIO_S32LSB,

SDL_AUDIO_F32LSB    = 0x8120,
SDL_AUDIO_F32MSB    = 0x9120,
SDL_AUDIO_F32       = SDL_AUDIO_F32LSB
};

enum {
SDL_AUDIO_ALLOW_FREQUENCY_CHANGE    = 0x00000001,
SDL_AUDIO_ALLOW_FORMAT_CHANGE       = 0x00000002,
SDL_AUDIO_ALLOW_CHANNELS_CHANGE     = 0x00000004,
SDL_AUDIO_ALLOW_ANY_CHANGE          = (SDL_AUDIO_ALLOW_FREQUENCY_CHANGE|SDL_AUDIO_ALLOW_FORMAT_CHANGE|SDL_AUDIO_ALLOW_CHANNELS_CHANGE),
SDL_MIX_MAXVOLUME = 128
};

\]\]

-- events

ffi.cdef\[\[
enum {
SDL_RELEASED = 0,
SDL_PRESSED  = 1,
SDL_QUERY    = -1,
SDL_IGNORE   = 0,
SDL_DISABLE  = 0,
SDL_ENABLE   = 1
};
\]\]

-- haptic

ffi.cdef\[\[
enum {
SDL_HAPTIC_CONSTANT   = (1<<0),
SDL_HAPTIC_SINE       = (1<<1),
SDL_HAPTIC_LEFTRIGHT     = (1<<2),
SDL_HAPTIC_TRIANGLE   = (1<<3),
SDL_HAPTIC_SAWTOOTHUP = (1<<4),
SDL_HAPTIC_SAWTOOTHDOWN = (1<<5),
SDL_HAPTIC_RAMP       = (1<<6),
SDL_HAPTIC_SPRING     = (1<<7),
SDL_HAPTIC_DAMPER     = (1<<8),
SDL_HAPTIC_INERTIA    = (1<<9),
SDL_HAPTIC_FRICTION   = (1<<10),
SDL_HAPTIC_CUSTOM     = (1<<11),
SDL_HAPTIC_GAIN       = (1<<12),
SDL_HAPTIC_AUTOCENTER = (1<<13),
SDL_HAPTIC_STATUS     = (1<<14),
SDL_HAPTIC_PAUSE      = (1<<15),
SDL_HAPTIC_POLAR      = 0,
SDL_HAPTIC_CARTESIAN  = 1,
SDL_HAPTIC_SPHERICAL  = 2,
SDL_HAPTIC_INFINITY   = 4294967295U
};
\]\]

-- joystick

ffi.cdef\[\[
enum {
SDL_HAT_CENTERED    = 0x00,
SDL_HAT_UP          = 0x01,
SDL_HAT_RIGHT       = 0x02,
SDL_HAT_DOWN        = 0x04,
SDL_HAT_LEFT        = 0x08,
SDL_HAT_RIGHTUP     = (SDL_HAT_RIGHT|SDL_HAT_UP),
SDL_HAT_RIGHTDOWN   = (SDL_HAT_RIGHT|SDL_HAT_DOWN),
SDL_HAT_LEFTUP      = (SDL_HAT_LEFT|SDL_HAT_UP),
SDL_HAT_LEFTDOWN    = (SDL_HAT_LEFT|SDL_HAT_DOWN)
};
\]\]

-- keycode

ffi.cdef\[\[
enum {
SDL_SCANCODE_MASK = (1<<30),
SDL_KMOD_CTRL = (SDL_KMOD_LCTRL|SDL_KMOD_RCTRL),
SDL_KMOD_SHIFT = (SDL_KMOD_LSHIFT|SDL_KMOD_RSHIFT),
SDL_KMOD_ALT = (SDL_KMOD_LALT|SDL_KMOD_RALT),
SDL_KMOD_GUI = (SDL_KMOD_LGUI|SDL_KMOD_RGUI)
};
\]\]

-- main
if jit.os == 'Windows' then
   ffi.cdef\[\[
int SDL_RegisterApp(char *name, Uint32 style,
                    void *hInst);
void SDL_UnregisterApp(void);
   \]\]
end

-- mouse

ffi.cdef\[\[
enum {
SDL_BUTTON_LEFT     = 1,
SDL_BUTTON_MIDDLE   = 2,
SDL_BUTTON_RIGHT    = 3,
SDL_BUTTON_X1       = 4,
SDL_BUTTON_X2       = 5,
SDL_BUTTON_LMASK    = 1 << (SDL_BUTTON_LEFT-1),
SDL_BUTTON_MMASK    = 1 << (SDL_BUTTON_MIDDLE-1),
SDL_BUTTON_RMASK    = 1 << (SDL_BUTTON_RIGHT-1),
SDL_BUTTON_X1MASK   = 1 << (SDL_BUTTON_X1-1),
SDL_BUTTON_X2MASK   = 1 << (SDL_BUTTON_X2-1),
};
\]\]

-- mutex

ffi.cdef\[\[
enum {
SDL_MUTEX_TIMEDOUT = 1,
SDL_MUTEX_MAXWAIT = (~(Uint32)0)
};
\]\]

-- pixels

ffi.cdef\[\[
enum {
SDL_ALPHA_OPAQUE = 255,
SDL_ALPHA_TRANSPARENT = 0
};
\]\]

-- rwops
ffi.cdef\[\[
enum {
SDL_RWOPS_UNKNOWN   = 0,
SDL_RWOPS_WINFILE   = 1,
SDL_RWOPS_STDFILE   = 2,
SDL_RWOPS_JNIFILE   = 3,
SDL_RWOPS_MEMORY    = 4,
SDL_RWOPS_MEMORY_RO = 5
};
\]\]

-- shape
ffi.cdef\[\[
enum {
SDL_NONSHAPEABLE_WINDOW = -1,
SDL_INVALID_SHAPE_ARGUMENT = -2,
SDL_WINDOW_LACKS_SHAPE = -3
};
\]\]

-- surface
ffi.cdef\[\[
enum {
SDL_SWSURFACE       = 0,
SDL_PREALLOC        = 0x00000001,
SDL_RLEACCEL        = 0x00000002,
SDL_DONTFREE        = 0x00000004
};
\]\]

-- video
ffi.cdef\[\[
enum {
SDL_WINDOWPOS_CENTERED_MASK  = 0x2FFF0000,
SDL_WINDOWPOS_CENTERED = 0x2FFF0000,
SDL_WINDOWPOS_UNDEFINED_MASK = 0x1FFF0000,
SDL_WINDOWPOS_UNDEFINED = 0x1FFF0000
};
\]\]
]]):gsub('\\([%]%[])','%1')
sources["hate.sdl2.init"]=([[-- <pack hate.sdl2.init> --
-- Do not change this file manually
-- Generated with dev/create-init.lua

local ffi = require 'ffi'
local C = ffi.load(ffi.os == "Windows" and 'bin/SDL2' or "SDL2")
local sdl = {C=C}
local current_folder = (...):gsub('%.\[^%.\]+$', '') .. "."
local registerdefines = require(current_folder .. "sdl2.defines")

require(current_folder .. "sdl2.cdefs")

local function register(luafuncname, funcname)
   local symexists, msg = pcall(function()
                              local sym = C\[funcname\]
                           end)
   if symexists then
      sdl\[luafuncname\] = C\[funcname\]
   end
end

register('getPlatform', 'SDL_GetPlatform')
register('malloc', 'SDL_malloc')
register('calloc', 'SDL_calloc')
register('realloc', 'SDL_realloc')
register('free', 'SDL_free')
register('getenv', 'SDL_getenv')
register('setenv', 'SDL_setenv')
register('qsort', 'SDL_qsort')
register('abs', 'SDL_abs')
register('isdigit', 'SDL_isdigit')
register('isspace', 'SDL_isspace')
register('toupper', 'SDL_toupper')
register('tolower', 'SDL_tolower')
register('memset', 'SDL_memset')
register('memcpy', 'SDL_memcpy')
register('memmove', 'SDL_memmove')
register('memcmp', 'SDL_memcmp')
register('wcslen', 'SDL_wcslen')
register('wcslcpy', 'SDL_wcslcpy')
register('wcslcat', 'SDL_wcslcat')
register('strlen', 'SDL_strlen')
register('strlcpy', 'SDL_strlcpy')
register('utf8strlcpy', 'SDL_utf8strlcpy')
register('strlcat', 'SDL_strlcat')
register('strdup', 'SDL_strdup')
register('strrev', 'SDL_strrev')
register('strupr', 'SDL_strupr')
register('strlwr', 'SDL_strlwr')
register('strchr', 'SDL_strchr')
register('strrchr', 'SDL_strrchr')
register('strstr', 'SDL_strstr')
register('itoa', 'SDL_itoa')
register('uitoa', 'SDL_uitoa')
register('ltoa', 'SDL_ltoa')
register('ultoa', 'SDL_ultoa')
register('lltoa', 'SDL_lltoa')
register('ulltoa', 'SDL_ulltoa')
register('atoi', 'SDL_atoi')
register('atof', 'SDL_atof')
register('strtol', 'SDL_strtol')
register('strtoul', 'SDL_strtoul')
register('strtoll', 'SDL_strtoll')
register('strtoull', 'SDL_strtoull')
register('strtod', 'SDL_strtod')
register('strcmp', 'SDL_strcmp')
register('strncmp', 'SDL_strncmp')
register('strcasecmp', 'SDL_strcasecmp')
register('strncasecmp', 'SDL_strncasecmp')
register('sscanf', 'SDL_sscanf')
register('snprintf', 'SDL_snprintf')
register('vsnprintf', 'SDL_vsnprintf')
register('atan', 'SDL_atan')
register('atan2', 'SDL_atan2')
register('ceil', 'SDL_ceil')
register('copysign', 'SDL_copysign')
register('cos', 'SDL_cos')
register('cosf', 'SDL_cosf')
register('fabs', 'SDL_fabs')
register('floor', 'SDL_floor')
register('log', 'SDL_log')
register('pow', 'SDL_pow')
register('scalbn', 'SDL_scalbn')
register('sin', 'SDL_sin')
register('sinf', 'SDL_sinf')
register('sqrt', 'SDL_sqrt')
register('iconv_open', 'SDL_iconv_open')
register('iconv_close', 'SDL_iconv_close')
register('iconv', 'SDL_iconv')
register('iconv_string', 'SDL_iconv_string')
register('main', 'SDL_main')
register('setMainReady', 'SDL_SetMainReady')
register('reportAssertion', 'SDL_ReportAssertion')
register('assert_state', 'SDL_assert_state')
register('setAssertionHandler', 'SDL_SetAssertionHandler')
register('getAssertionReport', 'SDL_GetAssertionReport')
register('resetAssertionReport', 'SDL_ResetAssertionReport')
register('atomicTryLock', 'SDL_AtomicTryLock')
register('atomicLock', 'SDL_AtomicLock')
register('atomicUnlock', 'SDL_AtomicUnlock')
register('setError', 'SDL_SetError')
register('getError', 'SDL_GetError')
register('clearError', 'SDL_ClearError')
register('error', 'SDL_Error')
register('createMutex', 'SDL_CreateMutex')
register('lockMutex', 'SDL_LockMutex')
register('tryLockMutex', 'SDL_TryLockMutex')
register('unlockMutex', 'SDL_UnlockMutex')
register('destroyMutex', 'SDL_DestroyMutex')
register('createSemaphore', 'SDL_CreateSemaphore')
register('destroySemaphore', 'SDL_DestroySemaphore')
register('semWait', 'SDL_SemWait')
register('semTryWait', 'SDL_SemTryWait')
register('semWaitTimeout', 'SDL_SemWaitTimeout')
register('semPost', 'SDL_SemPost')
register('semValue', 'SDL_SemValue')
register('createCond', 'SDL_CreateCond')
register('destroyCond', 'SDL_DestroyCond')
register('condSignal', 'SDL_CondSignal')
register('condBroadcast', 'SDL_CondBroadcast')
register('condWait', 'SDL_CondWait')
register('condWaitTimeout', 'SDL_CondWaitTimeout')

if jit.os == 'Windows' then
  sdl.createThread =
    function(fn, name, data)
      return C.SDL_CreateThread(fn, name, data, ffi.C._beginthreadex, ffi.C._endthreadex)
    end
else
  register('createThread', 'SDL_CreateThread')
end

register('getThreadName', 'SDL_GetThreadName')
register('threadID', 'SDL_ThreadID')
register('getThreadID', 'SDL_GetThreadID')
register('setThreadPriority', 'SDL_SetThreadPriority')
register('waitThread', 'SDL_WaitThread')
register('tLSCreate', 'SDL_TLSCreate')
register('tLSGet', 'SDL_TLSGet')
register('tLSSet', 'SDL_TLSSet')
register('RWFromFile', 'SDL_RWFromFile')
register('RWFromFP', 'SDL_RWFromFP')
register('RWFromMem', 'SDL_RWFromMem')
register('RWFromConstMem', 'SDL_RWFromConstMem')
register('allocRW', 'SDL_AllocRW')
register('freeRW', 'SDL_FreeRW')
register('readU8', 'SDL_ReadU8')
register('readLE16', 'SDL_ReadLE16')
register('readBE16', 'SDL_ReadBE16')
register('readLE32', 'SDL_ReadLE32')
register('readBE32', 'SDL_ReadBE32')
register('readLE64', 'SDL_ReadLE64')
register('readBE64', 'SDL_ReadBE64')
register('writeU8', 'SDL_WriteU8')
register('writeLE16', 'SDL_WriteLE16')
register('writeBE16', 'SDL_WriteBE16')
register('writeLE32', 'SDL_WriteLE32')
register('writeBE32', 'SDL_WriteBE32')
register('writeLE64', 'SDL_WriteLE64')
register('writeBE64', 'SDL_WriteBE64')
register('getNumAudioDrivers', 'SDL_GetNumAudioDrivers')
register('getAudioDriver', 'SDL_GetAudioDriver')
register('audioInit', 'SDL_AudioInit')
register('audioQuit', 'SDL_AudioQuit')
register('getCurrentAudioDriver', 'SDL_GetCurrentAudioDriver')
register('openAudio', 'SDL_OpenAudio')
register('getNumAudioDevices', 'SDL_GetNumAudioDevices')
register('getAudioDeviceName', 'SDL_GetAudioDeviceName')
register('openAudioDevice', 'SDL_OpenAudioDevice')
register('getAudioStatus', 'SDL_GetAudioStatus')
register('getAudioDeviceStatus', 'SDL_GetAudioDeviceStatus')
register('pauseAudio', 'SDL_PauseAudio')
register('pauseAudioDevice', 'SDL_PauseAudioDevice')
register('loadWAV_RW', 'SDL_LoadWAV_RW')
register('freeWAV', 'SDL_FreeWAV')
register('buildAudioCVT', 'SDL_BuildAudioCVT')
register('convertAudio', 'SDL_ConvertAudio')
register('mixAudio', 'SDL_MixAudio')
register('mixAudioFormat', 'SDL_MixAudioFormat')
register('lockAudio', 'SDL_LockAudio')
register('lockAudioDevice', 'SDL_LockAudioDevice')
register('unlockAudio', 'SDL_UnlockAudio')
register('unlockAudioDevice', 'SDL_UnlockAudioDevice')
register('closeAudio', 'SDL_CloseAudio')
register('closeAudioDevice', 'SDL_CloseAudioDevice')
register('setClipboardText', 'SDL_SetClipboardText')
register('getClipboardText', 'SDL_GetClipboardText')
register('hasClipboardText', 'SDL_HasClipboardText')
register('getCPUCount', 'SDL_GetCPUCount')
register('getCPUCacheLineSize', 'SDL_GetCPUCacheLineSize')
register('hasRDTSC', 'SDL_HasRDTSC')
register('hasAltiVec', 'SDL_HasAltiVec')
register('hasMMX', 'SDL_HasMMX')
register('has3DNow', 'SDL_Has3DNow')
register('hasSSE', 'SDL_HasSSE')
register('hasSSE2', 'SDL_HasSSE2')
register('hasSSE3', 'SDL_HasSSE3')
register('hasSSE41', 'SDL_HasSSE41')
register('hasSSE42', 'SDL_HasSSE42')
register('getPixelFormatName', 'SDL_GetPixelFormatName')
register('pixelFormatEnumToMasks', 'SDL_PixelFormatEnumToMasks')
register('masksToPixelFormatEnum', 'SDL_MasksToPixelFormatEnum')
register('allocFormat', 'SDL_AllocFormat')
register('freeFormat', 'SDL_FreeFormat')
register('allocPalette', 'SDL_AllocPalette')
register('setPixelFormatPalette', 'SDL_SetPixelFormatPalette')
register('setPaletteColors', 'SDL_SetPaletteColors')
register('freePalette', 'SDL_FreePalette')
register('mapRGB', 'SDL_MapRGB')
register('mapRGBA', 'SDL_MapRGBA')
register('getRGB', 'SDL_GetRGB')
register('getRGBA', 'SDL_GetRGBA')
register('calculateGammaRamp', 'SDL_CalculateGammaRamp')
register('hasIntersection', 'SDL_HasIntersection')
register('intersectRect', 'SDL_IntersectRect')
register('unionRect', 'SDL_UnionRect')
register('enclosePoints', 'SDL_EnclosePoints')
register('intersectRectAndLine', 'SDL_IntersectRectAndLine')
register('createRGBSurface', 'SDL_CreateRGBSurface')
register('createRGBSurfaceFrom', 'SDL_CreateRGBSurfaceFrom')
register('freeSurface', 'SDL_FreeSurface')
register('setSurfacePalette', 'SDL_SetSurfacePalette')
register('lockSurface', 'SDL_LockSurface')
register('unlockSurface', 'SDL_UnlockSurface')
register('loadBMP_RW', 'SDL_LoadBMP_RW')
register('saveBMP_RW', 'SDL_SaveBMP_RW')
register('setSurfaceRLE', 'SDL_SetSurfaceRLE')
register('setColorKey', 'SDL_SetColorKey')
register('getColorKey', 'SDL_GetColorKey')
register('setSurfaceColorMod', 'SDL_SetSurfaceColorMod')
register('getSurfaceColorMod', 'SDL_GetSurfaceColorMod')
register('setSurfaceAlphaMod', 'SDL_SetSurfaceAlphaMod')
register('getSurfaceAlphaMod', 'SDL_GetSurfaceAlphaMod')
register('setSurfaceBlendMode', 'SDL_SetSurfaceBlendMode')
register('getSurfaceBlendMode', 'SDL_GetSurfaceBlendMode')
register('setClipRect', 'SDL_SetClipRect')
register('getClipRect', 'SDL_GetClipRect')
register('convertSurface', 'SDL_ConvertSurface')
register('convertSurfaceFormat', 'SDL_ConvertSurfaceFormat')
register('convertPixels', 'SDL_ConvertPixels')
register('fillRect', 'SDL_FillRect')
register('fillRects', 'SDL_FillRects')
register('upperBlit', 'SDL_UpperBlit')
register('lowerBlit', 'SDL_LowerBlit')
register('softStretch', 'SDL_SoftStretch')
register('upperBlitScaled', 'SDL_UpperBlitScaled')
register('lowerBlitScaled', 'SDL_LowerBlitScaled')
register('getNumVideoDrivers', 'SDL_GetNumVideoDrivers')
register('getVideoDriver', 'SDL_GetVideoDriver')
register('videoInit', 'SDL_VideoInit')
register('videoQuit', 'SDL_VideoQuit')
register('getCurrentVideoDriver', 'SDL_GetCurrentVideoDriver')
register('getNumVideoDisplays', 'SDL_GetNumVideoDisplays')
register('getDisplayName', 'SDL_GetDisplayName')
register('getDisplayBounds', 'SDL_GetDisplayBounds')
register('getNumDisplayModes', 'SDL_GetNumDisplayModes')
register('getDisplayMode', 'SDL_GetDisplayMode')
register('getDesktopDisplayMode', 'SDL_GetDesktopDisplayMode')
register('getCurrentDisplayMode', 'SDL_GetCurrentDisplayMode')
register('getClosestDisplayMode', 'SDL_GetClosestDisplayMode')
register('getWindowDisplayIndex', 'SDL_GetWindowDisplayIndex')
register('setWindowDisplayMode', 'SDL_SetWindowDisplayMode')
register('getWindowDisplayMode', 'SDL_GetWindowDisplayMode')
register('getWindowPixelFormat', 'SDL_GetWindowPixelFormat')
register('createWindow', 'SDL_CreateWindow')
register('createWindowFrom', 'SDL_CreateWindowFrom')
register('getWindowID', 'SDL_GetWindowID')
register('getWindowFromID', 'SDL_GetWindowFromID')
register('getWindowFlags', 'SDL_GetWindowFlags')
register('setWindowTitle', 'SDL_SetWindowTitle')
register('getWindowTitle', 'SDL_GetWindowTitle')
register('setWindowIcon', 'SDL_SetWindowIcon')
register('setWindowData', 'SDL_SetWindowData')
register('getWindowData', 'SDL_GetWindowData')
register('setWindowPosition', 'SDL_SetWindowPosition')
register('getWindowPosition', 'SDL_GetWindowPosition')
register('setWindowSize', 'SDL_SetWindowSize')
register('getWindowSize', 'SDL_GetWindowSize')
register('setWindowMinimumSize', 'SDL_SetWindowMinimumSize')
register('getWindowMinimumSize', 'SDL_GetWindowMinimumSize')
register('setWindowMaximumSize', 'SDL_SetWindowMaximumSize')
register('getWindowMaximumSize', 'SDL_GetWindowMaximumSize')
register('setWindowBordered', 'SDL_SetWindowBordered')
register('showWindow', 'SDL_ShowWindow')
register('hideWindow', 'SDL_HideWindow')
register('raiseWindow', 'SDL_RaiseWindow')
register('maximizeWindow', 'SDL_MaximizeWindow')
register('minimizeWindow', 'SDL_MinimizeWindow')
register('restoreWindow', 'SDL_RestoreWindow')
register('setWindowFullscreen', 'SDL_SetWindowFullscreen')
register('getWindowSurface', 'SDL_GetWindowSurface')
register('updateWindowSurface', 'SDL_UpdateWindowSurface')
register('updateWindowSurfaceRects', 'SDL_UpdateWindowSurfaceRects')
register('setWindowGrab', 'SDL_SetWindowGrab')
register('getWindowGrab', 'SDL_GetWindowGrab')
register('setWindowBrightness', 'SDL_SetWindowBrightness')
register('getWindowBrightness', 'SDL_GetWindowBrightness')
register('setWindowGammaRamp', 'SDL_SetWindowGammaRamp')
register('getWindowGammaRamp', 'SDL_GetWindowGammaRamp')
register('destroyWindow', 'SDL_DestroyWindow')
register('isScreenSaverEnabled', 'SDL_IsScreenSaverEnabled')
register('enableScreenSaver', 'SDL_EnableScreenSaver')
register('disableScreenSaver', 'SDL_DisableScreenSaver')
register('GL_LoadLibrary', 'SDL_GL_LoadLibrary')
register('GL_GetProcAddress', 'SDL_GL_GetProcAddress')
register('GL_UnloadLibrary', 'SDL_GL_UnloadLibrary')
register('GL_ExtensionSupported', 'SDL_GL_ExtensionSupported')
register('GL_SetAttribute', 'SDL_GL_SetAttribute')
register('GL_GetAttribute', 'SDL_GL_GetAttribute')
register('GL_CreateContext', 'SDL_GL_CreateContext')
register('GL_MakeCurrent', 'SDL_GL_MakeCurrent')
register('GL_GetCurrentWindow', 'SDL_GL_GetCurrentWindow')
register('GL_GetCurrentContext', 'SDL_GL_GetCurrentContext')
register('GL_SetSwapInterval', 'SDL_GL_SetSwapInterval')
register('GL_GetSwapInterval', 'SDL_GL_GetSwapInterval')
register('GL_SwapWindow', 'SDL_GL_SwapWindow')
register('GL_DeleteContext', 'SDL_GL_DeleteContext')
register('GL_GetDrawableSize', 'SDL_GL_GetDrawableSize')
register('getKeyboardFocus', 'SDL_GetKeyboardFocus')
register('getKeyboardState', 'SDL_GetKeyboardState')
register('getModState', 'SDL_GetModState')
register('setModState', 'SDL_SetModState')
register('getKeyFromScancode', 'SDL_GetKeyFromScancode')
register('getScancodeFromKey', 'SDL_GetScancodeFromKey')
register('getScancodeName', 'SDL_GetScancodeName')
register('getScancodeFromName', 'SDL_GetScancodeFromName')
register('getKeyName', 'SDL_GetKeyName')
register('getKeyFromName', 'SDL_GetKeyFromName')
register('startTextInput', 'SDL_StartTextInput')
register('isTextInputActive', 'SDL_IsTextInputActive')
register('stopTextInput', 'SDL_StopTextInput')
register('setTextInputRect', 'SDL_SetTextInputRect')
register('hasScreenKeyboardSupport', 'SDL_HasScreenKeyboardSupport')
register('isScreenKeyboardShown', 'SDL_IsScreenKeyboardShown')
register('getMouseFocus', 'SDL_GetMouseFocus')
register('getMouseState', 'SDL_GetMouseState')
register('getRelativeMouseState', 'SDL_GetRelativeMouseState')
register('warpMouseInWindow', 'SDL_WarpMouseInWindow')
register('setRelativeMouseMode', 'SDL_SetRelativeMouseMode')
register('getRelativeMouseMode', 'SDL_GetRelativeMouseMode')
register('createCursor', 'SDL_CreateCursor')
register('createColorCursor', 'SDL_CreateColorCursor')
register('createSystemCursor', 'SDL_CreateSystemCursor')
register('setCursor', 'SDL_SetCursor')
register('getCursor', 'SDL_GetCursor')
register('getDefaultCursor', 'SDL_GetDefaultCursor')
register('freeCursor', 'SDL_FreeCursor')
register('showCursor', 'SDL_ShowCursor')
register('numJoysticks', 'SDL_NumJoysticks')
register('joystickNameForIndex', 'SDL_JoystickNameForIndex')
register('joystickOpen', 'SDL_JoystickOpen')
register('joystickName', 'SDL_JoystickName')
register('joystickGetDeviceGUID', 'SDL_JoystickGetDeviceGUID')
register('joystickGetGUID', 'SDL_JoystickGetGUID')
register('joystickGetGUIDString', 'SDL_JoystickGetGUIDString')
register('joystickGetGUIDFromString', 'SDL_JoystickGetGUIDFromString')
register('joystickGetAttached', 'SDL_JoystickGetAttached')
register('joystickInstanceID', 'SDL_JoystickInstanceID')
register('joystickNumAxes', 'SDL_JoystickNumAxes')
register('joystickNumBalls', 'SDL_JoystickNumBalls')
register('joystickNumHats', 'SDL_JoystickNumHats')
register('joystickNumButtons', 'SDL_JoystickNumButtons')
register('joystickUpdate', 'SDL_JoystickUpdate')
register('joystickEventState', 'SDL_JoystickEventState')
register('joystickGetAxis', 'SDL_JoystickGetAxis')
register('joystickGetHat', 'SDL_JoystickGetHat')
register('joystickGetBall', 'SDL_JoystickGetBall')
register('joystickGetButton', 'SDL_JoystickGetButton')
register('joystickClose', 'SDL_JoystickClose')
register('gameControllerAddMapping', 'SDL_GameControllerAddMapping')
register('gameControllerMappingForGUID', 'SDL_GameControllerMappingForGUID')
register('gameControllerMapping', 'SDL_GameControllerMapping')
register('isGameController', 'SDL_IsGameController')
register('gameControllerNameForIndex', 'SDL_GameControllerNameForIndex')
register('gameControllerOpen', 'SDL_GameControllerOpen')
register('gameControllerName', 'SDL_GameControllerName')
register('gameControllerGetAttached', 'SDL_GameControllerGetAttached')
register('gameControllerGetJoystick', 'SDL_GameControllerGetJoystick')
register('gameControllerEventState', 'SDL_GameControllerEventState')
register('gameControllerUpdate', 'SDL_GameControllerUpdate')
register('gameControllerGetAxisFromString', 'SDL_GameControllerGetAxisFromString')
register('gameControllerGetStringForAxis', 'SDL_GameControllerGetStringForAxis')
register('gameControllerGetBindForAxis', 'SDL_GameControllerGetBindForAxis')
register('gameControllerGetAxis', 'SDL_GameControllerGetAxis')
register('gameControllerGetButtonFromString', 'SDL_GameControllerGetButtonFromString')
register('gameControllerGetStringForButton', 'SDL_GameControllerGetStringForButton')
register('gameControllerGetBindForButton', 'SDL_GameControllerGetBindForButton')
register('gameControllerGetButton', 'SDL_GameControllerGetButton')
register('gameControllerClose', 'SDL_GameControllerClose')
register('getNumTouchDevices', 'SDL_GetNumTouchDevices')
register('getTouchDevice', 'SDL_GetTouchDevice')
register('getNumTouchFingers', 'SDL_GetNumTouchFingers')
register('getTouchFinger', 'SDL_GetTouchFinger')
register('recordGesture', 'SDL_RecordGesture')
register('saveAllDollarTemplates', 'SDL_SaveAllDollarTemplates')
register('saveDollarTemplate', 'SDL_SaveDollarTemplate')
register('loadDollarTemplates', 'SDL_LoadDollarTemplates')
register('pumpEvents', 'SDL_PumpEvents')
register('peepEvents', 'SDL_PeepEvents')
register('hasEvent', 'SDL_HasEvent')
register('hasEvents', 'SDL_HasEvents')
register('flushEvent', 'SDL_FlushEvent')
register('flushEvents', 'SDL_FlushEvents')
register('pollEvent', 'SDL_PollEvent')
register('waitEvent', 'SDL_WaitEvent')
register('waitEventTimeout', 'SDL_WaitEventTimeout')
register('pushEvent', 'SDL_PushEvent')
register('setEventFilter', 'SDL_SetEventFilter')
register('getEventFilter', 'SDL_GetEventFilter')
register('addEventWatch', 'SDL_AddEventWatch')
register('delEventWatch', 'SDL_DelEventWatch')
register('filterEvents', 'SDL_FilterEvents')
register('eventState', 'SDL_EventState')
register('registerEvents', 'SDL_RegisterEvents')
register('numHaptics', 'SDL_NumHaptics')
register('hapticName', 'SDL_HapticName')
register('hapticOpen', 'SDL_HapticOpen')
register('hapticOpened', 'SDL_HapticOpened')
register('hapticIndex', 'SDL_HapticIndex')
register('mouseIsHaptic', 'SDL_MouseIsHaptic')
register('hapticOpenFromMouse', 'SDL_HapticOpenFromMouse')
register('joystickIsHaptic', 'SDL_JoystickIsHaptic')
register('hapticOpenFromJoystick', 'SDL_HapticOpenFromJoystick')
register('hapticClose', 'SDL_HapticClose')
register('hapticNumEffects', 'SDL_HapticNumEffects')
register('hapticNumEffectsPlaying', 'SDL_HapticNumEffectsPlaying')
register('hapticQuery', 'SDL_HapticQuery')
register('hapticNumAxes', 'SDL_HapticNumAxes')
register('hapticEffectSupported', 'SDL_HapticEffectSupported')
register('hapticNewEffect', 'SDL_HapticNewEffect')
register('hapticUpdateEffect', 'SDL_HapticUpdateEffect')
register('hapticRunEffect', 'SDL_HapticRunEffect')
register('hapticStopEffect', 'SDL_HapticStopEffect')
register('hapticDestroyEffect', 'SDL_HapticDestroyEffect')
register('hapticGetEffectStatus', 'SDL_HapticGetEffectStatus')
register('hapticSetGain', 'SDL_HapticSetGain')
register('hapticSetAutocenter', 'SDL_HapticSetAutocenter')
register('hapticPause', 'SDL_HapticPause')
register('hapticUnpause', 'SDL_HapticUnpause')
register('hapticStopAll', 'SDL_HapticStopAll')
register('hapticRumbleSupported', 'SDL_HapticRumbleSupported')
register('hapticRumbleInit', 'SDL_HapticRumbleInit')
register('hapticRumblePlay', 'SDL_HapticRumblePlay')
register('hapticRumbleStop', 'SDL_HapticRumbleStop')
register('setHintWithPriority', 'SDL_SetHintWithPriority')
register('setHint', 'SDL_SetHint')
register('getHint', 'SDL_GetHint')
register('addHintCallback', 'SDL_AddHintCallback')
register('delHintCallback', 'SDL_DelHintCallback')
register('clearHints', 'SDL_ClearHints')
register('loadObject', 'SDL_LoadObject')
register('loadFunction', 'SDL_LoadFunction')
register('unloadObject', 'SDL_UnloadObject')
register('logSetAllPriority', 'SDL_LogSetAllPriority')
register('logSetPriority', 'SDL_LogSetPriority')
register('logGetPriority', 'SDL_LogGetPriority')
register('logResetPriorities', 'SDL_LogResetPriorities')
register('log', 'SDL_Log')
register('logVerbose', 'SDL_LogVerbose')
register('logDebug', 'SDL_LogDebug')
register('logInfo', 'SDL_LogInfo')
register('logWarn', 'SDL_LogWarn')
register('logError', 'SDL_LogError')
register('logCritical', 'SDL_LogCritical')
register('logMessage', 'SDL_LogMessage')
register('logMessageV', 'SDL_LogMessageV')
register('logGetOutputFunction', 'SDL_LogGetOutputFunction')
register('logSetOutputFunction', 'SDL_LogSetOutputFunction')
register('showMessageBox', 'SDL_ShowMessageBox')
register('showSimpleMessageBox', 'SDL_ShowSimpleMessageBox')
register('getPowerInfo', 'SDL_GetPowerInfo')
register('getNumRenderDrivers', 'SDL_GetNumRenderDrivers')
register('getRenderDriverInfo', 'SDL_GetRenderDriverInfo')
register('createWindowAndRenderer', 'SDL_CreateWindowAndRenderer')
register('createRenderer', 'SDL_CreateRenderer')
register('createSoftwareRenderer', 'SDL_CreateSoftwareRenderer')
register('getRenderer', 'SDL_GetRenderer')
register('getRendererInfo', 'SDL_GetRendererInfo')
register('getRendererOutputSize', 'SDL_GetRendererOutputSize')
register('createTexture', 'SDL_CreateTexture')
register('createTextureFromSurface', 'SDL_CreateTextureFromSurface')
register('queryTexture', 'SDL_QueryTexture')
register('setTextureColorMod', 'SDL_SetTextureColorMod')
register('getTextureColorMod', 'SDL_GetTextureColorMod')
register('setTextureAlphaMod', 'SDL_SetTextureAlphaMod')
register('getTextureAlphaMod', 'SDL_GetTextureAlphaMod')
register('setTextureBlendMode', 'SDL_SetTextureBlendMode')
register('getTextureBlendMode', 'SDL_GetTextureBlendMode')
register('updateTexture', 'SDL_UpdateTexture')
register('lockTexture', 'SDL_LockTexture')
register('unlockTexture', 'SDL_UnlockTexture')
register('renderTargetSupported', 'SDL_RenderTargetSupported')
register('setRenderTarget', 'SDL_SetRenderTarget')
register('getRenderTarget', 'SDL_GetRenderTarget')
register('renderSetLogicalSize', 'SDL_RenderSetLogicalSize')
register('renderGetLogicalSize', 'SDL_RenderGetLogicalSize')
register('renderSetViewport', 'SDL_RenderSetViewport')
register('renderGetViewport', 'SDL_RenderGetViewport')
register('renderSetClipRect', 'SDL_RenderSetClipRect')
register('renderGetClipRect', 'SDL_RenderGetClipRect')
register('renderSetScale', 'SDL_RenderSetScale')
register('renderGetScale', 'SDL_RenderGetScale')
register('setRenderDrawColor', 'SDL_SetRenderDrawColor')
register('getRenderDrawColor', 'SDL_GetRenderDrawColor')
register('setRenderDrawBlendMode', 'SDL_SetRenderDrawBlendMode')
register('getRenderDrawBlendMode', 'SDL_GetRenderDrawBlendMode')
register('renderClear', 'SDL_RenderClear')
register('renderDrawPoint', 'SDL_RenderDrawPoint')
register('renderDrawPoints', 'SDL_RenderDrawPoints')
register('renderDrawLine', 'SDL_RenderDrawLine')
register('renderDrawLines', 'SDL_RenderDrawLines')
register('renderDrawRect', 'SDL_RenderDrawRect')
register('renderDrawRects', 'SDL_RenderDrawRects')
register('renderFillRect', 'SDL_RenderFillRect')
register('renderFillRects', 'SDL_RenderFillRects')
register('renderCopy', 'SDL_RenderCopy')
register('renderCopyEx', 'SDL_RenderCopyEx')
register('renderReadPixels', 'SDL_RenderReadPixels')
register('renderPresent', 'SDL_RenderPresent')
register('destroyTexture', 'SDL_DestroyTexture')
register('destroyRenderer', 'SDL_DestroyRenderer')
register('gL_BindTexture', 'SDL_GL_BindTexture')
register('gL_UnbindTexture', 'SDL_GL_UnbindTexture')
register('getTicks', 'SDL_GetTicks')
register('getPerformanceCounter', 'SDL_GetPerformanceCounter')
register('getPerformanceFrequency', 'SDL_GetPerformanceFrequency')
register('delay', 'SDL_Delay')
register('addTimer', 'SDL_AddTimer')
register('removeTimer', 'SDL_RemoveTimer')
register('getVersion', 'SDL_GetVersion')
register('getRevision', 'SDL_GetRevision')
register('getRevisionNumber', 'SDL_GetRevisionNumber')
register('init', 'SDL_Init')
register('initSubSystem', 'SDL_InitSubSystem')
register('quitSubSystem', 'SDL_QuitSubSystem')
register('wasInit', 'SDL_WasInit')
register('quit', 'SDL_Quit')
register('registerApp', 'SDL_RegisterApp')
register('unregisterApp', 'SDL_UnregisterApp')

register('FALSE', 'SDL_FALSE')
register('TRUE', 'SDL_TRUE')
register('DUMMY_ENUM', 'SDL_DUMMY_ENUM')
register('DUMMY_ENUM', 'SDL_DUMMY_ENUM')
register('ASSERTION_RETRY', 'SDL_ASSERTION_RETRY')
register('ASSERTION_BREAK', 'SDL_ASSERTION_BREAK')
register('ASSERTION_ABORT', 'SDL_ASSERTION_ABORT')
register('ASSERTION_IGNORE', 'SDL_ASSERTION_IGNORE')
register('ASSERTION_ALWAYS_IGNORE', 'SDL_ASSERTION_ALWAYS_IGNORE')
register('ENOMEM', 'SDL_ENOMEM')
register('EFREAD', 'SDL_EFREAD')
register('EFWRITE', 'SDL_EFWRITE')
register('EFSEEK', 'SDL_EFSEEK')
register('UNSUPPORTED', 'SDL_UNSUPPORTED')
register('LASTERROR', 'SDL_LASTERROR')
register('TLSID', 'SDL_TLSID')
register('THREAD_PRIORITY_LOW', 'SDL_THREAD_PRIORITY_LOW')
register('THREAD_PRIORITY_NORMAL', 'SDL_THREAD_PRIORITY_NORMAL')
register('THREAD_PRIORITY_HIGH', 'SDL_THREAD_PRIORITY_HIGH')
register('TLSID', 'SDL_TLSID')
register('TLSID', 'SDL_TLSID')
register('TLSID', 'SDL_TLSID')
register('AUDIO_STOPPED', 'SDL_AUDIO_STOPPED')
register('AUDIO_PLAYING', 'SDL_AUDIO_PLAYING')
register('AUDIO_PAUSED', 'SDL_AUDIO_PAUSED')
register('PIXELTYPE_UNKNOWN', 'SDL_PIXELTYPE_UNKNOWN')
register('PIXELTYPE_INDEX1', 'SDL_PIXELTYPE_INDEX1')
register('PIXELTYPE_INDEX4', 'SDL_PIXELTYPE_INDEX4')
register('PIXELTYPE_INDEX8', 'SDL_PIXELTYPE_INDEX8')
register('PIXELTYPE_PACKED8', 'SDL_PIXELTYPE_PACKED8')
register('PIXELTYPE_PACKED16', 'SDL_PIXELTYPE_PACKED16')
register('PIXELTYPE_PACKED32', 'SDL_PIXELTYPE_PACKED32')
register('PIXELTYPE_ARRAYU8', 'SDL_PIXELTYPE_ARRAYU8')
register('PIXELTYPE_ARRAYU16', 'SDL_PIXELTYPE_ARRAYU16')
register('PIXELTYPE_ARRAYU32', 'SDL_PIXELTYPE_ARRAYU32')
register('PIXELTYPE_ARRAYF16', 'SDL_PIXELTYPE_ARRAYF16')
register('PIXELTYPE_ARRAYF32', 'SDL_PIXELTYPE_ARRAYF32')
register('BITMAPORDER_NONE', 'SDL_BITMAPORDER_NONE')
register('BITMAPORDER_4321', 'SDL_BITMAPORDER_4321')
register('BITMAPORDER_1234', 'SDL_BITMAPORDER_1234')
register('PACKEDORDER_NONE', 'SDL_PACKEDORDER_NONE')
register('PACKEDORDER_XRGB', 'SDL_PACKEDORDER_XRGB')
register('PACKEDORDER_RGBX', 'SDL_PACKEDORDER_RGBX')
register('PACKEDORDER_ARGB', 'SDL_PACKEDORDER_ARGB')
register('PACKEDORDER_RGBA', 'SDL_PACKEDORDER_RGBA')
register('PACKEDORDER_XBGR', 'SDL_PACKEDORDER_XBGR')
register('PACKEDORDER_BGRX', 'SDL_PACKEDORDER_BGRX')
register('PACKEDORDER_ABGR', 'SDL_PACKEDORDER_ABGR')
register('PACKEDORDER_BGRA', 'SDL_PACKEDORDER_BGRA')
register('ARRAYORDER_NONE', 'SDL_ARRAYORDER_NONE')
register('ARRAYORDER_RGB', 'SDL_ARRAYORDER_RGB')
register('ARRAYORDER_RGBA', 'SDL_ARRAYORDER_RGBA')
register('ARRAYORDER_ARGB', 'SDL_ARRAYORDER_ARGB')
register('ARRAYORDER_BGR', 'SDL_ARRAYORDER_BGR')
register('ARRAYORDER_BGRA', 'SDL_ARRAYORDER_BGRA')
register('ARRAYORDER_ABGR', 'SDL_ARRAYORDER_ABGR')
register('PACKEDLAYOUT_NONE', 'SDL_PACKEDLAYOUT_NONE')
register('PACKEDLAYOUT_332', 'SDL_PACKEDLAYOUT_332')
register('PACKEDLAYOUT_4444', 'SDL_PACKEDLAYOUT_4444')
register('PACKEDLAYOUT_1555', 'SDL_PACKEDLAYOUT_1555')
register('PACKEDLAYOUT_5551', 'SDL_PACKEDLAYOUT_5551')
register('PACKEDLAYOUT_565', 'SDL_PACKEDLAYOUT_565')
register('PACKEDLAYOUT_8888', 'SDL_PACKEDLAYOUT_8888')
register('PACKEDLAYOUT_2101010', 'SDL_PACKEDLAYOUT_2101010')
register('PACKEDLAYOUT_1010102', 'SDL_PACKEDLAYOUT_1010102')
register('PIXELFORMAT_UNKNOWN', 'SDL_PIXELFORMAT_UNKNOWN')
register('PIXELFORMAT_INDEX1LSB', 'SDL_PIXELFORMAT_INDEX1LSB')
register('PIXELTYPE_INDEX1', 'SDL_PIXELTYPE_INDEX1')
register('BITMAPORDER_4321', 'SDL_BITMAPORDER_4321')
register('PIXELFORMAT_INDEX1MSB', 'SDL_PIXELFORMAT_INDEX1MSB')
register('PIXELTYPE_INDEX1', 'SDL_PIXELTYPE_INDEX1')
register('BITMAPORDER_1234', 'SDL_BITMAPORDER_1234')
register('PIXELFORMAT_INDEX4LSB', 'SDL_PIXELFORMAT_INDEX4LSB')
register('PIXELTYPE_INDEX4', 'SDL_PIXELTYPE_INDEX4')
register('BITMAPORDER_4321', 'SDL_BITMAPORDER_4321')
register('PIXELFORMAT_INDEX4MSB', 'SDL_PIXELFORMAT_INDEX4MSB')
register('PIXELTYPE_INDEX4', 'SDL_PIXELTYPE_INDEX4')
register('BITMAPORDER_1234', 'SDL_BITMAPORDER_1234')
register('PIXELFORMAT_INDEX8', 'SDL_PIXELFORMAT_INDEX8')
register('PIXELTYPE_INDEX8', 'SDL_PIXELTYPE_INDEX8')
register('PIXELFORMAT_RGB332', 'SDL_PIXELFORMAT_RGB332')
register('PIXELTYPE_PACKED8', 'SDL_PIXELTYPE_PACKED8')
register('PACKEDORDER_XRGB', 'SDL_PACKEDORDER_XRGB')
register('PACKEDLAYOUT_332', 'SDL_PACKEDLAYOUT_332')
register('PIXELFORMAT_RGB444', 'SDL_PIXELFORMAT_RGB444')
register('PIXELTYPE_PACKED16', 'SDL_PIXELTYPE_PACKED16')
register('PACKEDORDER_XRGB', 'SDL_PACKEDORDER_XRGB')
register('PACKEDLAYOUT_4444', 'SDL_PACKEDLAYOUT_4444')
register('PIXELFORMAT_RGB555', 'SDL_PIXELFORMAT_RGB555')
register('PIXELTYPE_PACKED16', 'SDL_PIXELTYPE_PACKED16')
register('PACKEDORDER_XRGB', 'SDL_PACKEDORDER_XRGB')
register('PACKEDLAYOUT_1555', 'SDL_PACKEDLAYOUT_1555')
register('PIXELFORMAT_BGR555', 'SDL_PIXELFORMAT_BGR555')
register('PIXELTYPE_PACKED16', 'SDL_PIXELTYPE_PACKED16')
register('PACKEDORDER_XBGR', 'SDL_PACKEDORDER_XBGR')
register('PACKEDLAYOUT_1555', 'SDL_PACKEDLAYOUT_1555')
register('PIXELFORMAT_ARGB4444', 'SDL_PIXELFORMAT_ARGB4444')
register('PIXELTYPE_PACKED16', 'SDL_PIXELTYPE_PACKED16')
register('PACKEDORDER_ARGB', 'SDL_PACKEDORDER_ARGB')
register('PACKEDLAYOUT_4444', 'SDL_PACKEDLAYOUT_4444')
register('PIXELFORMAT_RGBA4444', 'SDL_PIXELFORMAT_RGBA4444')
register('PIXELTYPE_PACKED16', 'SDL_PIXELTYPE_PACKED16')
register('PACKEDORDER_RGBA', 'SDL_PACKEDORDER_RGBA')
register('PACKEDLAYOUT_4444', 'SDL_PACKEDLAYOUT_4444')
register('PIXELFORMAT_ABGR4444', 'SDL_PIXELFORMAT_ABGR4444')
register('PIXELTYPE_PACKED16', 'SDL_PIXELTYPE_PACKED16')
register('PACKEDORDER_ABGR', 'SDL_PACKEDORDER_ABGR')
register('PACKEDLAYOUT_4444', 'SDL_PACKEDLAYOUT_4444')
register('PIXELFORMAT_BGRA4444', 'SDL_PIXELFORMAT_BGRA4444')
register('PIXELTYPE_PACKED16', 'SDL_PIXELTYPE_PACKED16')
register('PACKEDORDER_BGRA', 'SDL_PACKEDORDER_BGRA')
register('PACKEDLAYOUT_4444', 'SDL_PACKEDLAYOUT_4444')
register('PIXELFORMAT_ARGB1555', 'SDL_PIXELFORMAT_ARGB1555')
register('PIXELTYPE_PACKED16', 'SDL_PIXELTYPE_PACKED16')
register('PACKEDORDER_ARGB', 'SDL_PACKEDORDER_ARGB')
register('PACKEDLAYOUT_1555', 'SDL_PACKEDLAYOUT_1555')
register('PIXELFORMAT_RGBA5551', 'SDL_PIXELFORMAT_RGBA5551')
register('PIXELTYPE_PACKED16', 'SDL_PIXELTYPE_PACKED16')
register('PACKEDORDER_RGBA', 'SDL_PACKEDORDER_RGBA')
register('PACKEDLAYOUT_5551', 'SDL_PACKEDLAYOUT_5551')
register('PIXELFORMAT_ABGR1555', 'SDL_PIXELFORMAT_ABGR1555')
register('PIXELTYPE_PACKED16', 'SDL_PIXELTYPE_PACKED16')
register('PACKEDORDER_ABGR', 'SDL_PACKEDORDER_ABGR')
register('PACKEDLAYOUT_1555', 'SDL_PACKEDLAYOUT_1555')
register('PIXELFORMAT_BGRA5551', 'SDL_PIXELFORMAT_BGRA5551')
register('PIXELTYPE_PACKED16', 'SDL_PIXELTYPE_PACKED16')
register('PACKEDORDER_BGRA', 'SDL_PACKEDORDER_BGRA')
register('PACKEDLAYOUT_5551', 'SDL_PACKEDLAYOUT_5551')
register('PIXELFORMAT_RGB565', 'SDL_PIXELFORMAT_RGB565')
register('PIXELTYPE_PACKED16', 'SDL_PIXELTYPE_PACKED16')
register('PACKEDORDER_XRGB', 'SDL_PACKEDORDER_XRGB')
register('PACKEDLAYOUT_565', 'SDL_PACKEDLAYOUT_565')
register('PIXELFORMAT_BGR565', 'SDL_PIXELFORMAT_BGR565')
register('PIXELTYPE_PACKED16', 'SDL_PIXELTYPE_PACKED16')
register('PACKEDORDER_XBGR', 'SDL_PACKEDORDER_XBGR')
register('PACKEDLAYOUT_565', 'SDL_PACKEDLAYOUT_565')
register('PIXELFORMAT_RGB24', 'SDL_PIXELFORMAT_RGB24')
register('PIXELTYPE_ARRAYU8', 'SDL_PIXELTYPE_ARRAYU8')
register('ARRAYORDER_RGB', 'SDL_ARRAYORDER_RGB')
register('PIXELFORMAT_BGR24', 'SDL_PIXELFORMAT_BGR24')
register('PIXELTYPE_ARRAYU8', 'SDL_PIXELTYPE_ARRAYU8')
register('ARRAYORDER_BGR', 'SDL_ARRAYORDER_BGR')
register('PIXELFORMAT_RGB888', 'SDL_PIXELFORMAT_RGB888')
register('PIXELTYPE_PACKED32', 'SDL_PIXELTYPE_PACKED32')
register('PACKEDORDER_XRGB', 'SDL_PACKEDORDER_XRGB')
register('PACKEDLAYOUT_8888', 'SDL_PACKEDLAYOUT_8888')
register('PIXELFORMAT_RGBX8888', 'SDL_PIXELFORMAT_RGBX8888')
register('PIXELTYPE_PACKED32', 'SDL_PIXELTYPE_PACKED32')
register('PACKEDORDER_RGBX', 'SDL_PACKEDORDER_RGBX')
register('PACKEDLAYOUT_8888', 'SDL_PACKEDLAYOUT_8888')
register('PIXELFORMAT_BGR888', 'SDL_PIXELFORMAT_BGR888')
register('PIXELTYPE_PACKED32', 'SDL_PIXELTYPE_PACKED32')
register('PACKEDORDER_XBGR', 'SDL_PACKEDORDER_XBGR')
register('PACKEDLAYOUT_8888', 'SDL_PACKEDLAYOUT_8888')
register('PIXELFORMAT_BGRX8888', 'SDL_PIXELFORMAT_BGRX8888')
register('PIXELTYPE_PACKED32', 'SDL_PIXELTYPE_PACKED32')
register('PACKEDORDER_BGRX', 'SDL_PACKEDORDER_BGRX')
register('PACKEDLAYOUT_8888', 'SDL_PACKEDLAYOUT_8888')
register('PIXELFORMAT_ARGB8888', 'SDL_PIXELFORMAT_ARGB8888')
register('PIXELTYPE_PACKED32', 'SDL_PIXELTYPE_PACKED32')
register('PACKEDORDER_ARGB', 'SDL_PACKEDORDER_ARGB')
register('PACKEDLAYOUT_8888', 'SDL_PACKEDLAYOUT_8888')
register('PIXELFORMAT_RGBA8888', 'SDL_PIXELFORMAT_RGBA8888')
register('PIXELTYPE_PACKED32', 'SDL_PIXELTYPE_PACKED32')
register('PACKEDORDER_RGBA', 'SDL_PACKEDORDER_RGBA')
register('PACKEDLAYOUT_8888', 'SDL_PACKEDLAYOUT_8888')
register('PIXELFORMAT_ABGR8888', 'SDL_PIXELFORMAT_ABGR8888')
register('PIXELTYPE_PACKED32', 'SDL_PIXELTYPE_PACKED32')
register('PACKEDORDER_ABGR', 'SDL_PACKEDORDER_ABGR')
register('PACKEDLAYOUT_8888', 'SDL_PACKEDLAYOUT_8888')
register('PIXELFORMAT_BGRA8888', 'SDL_PIXELFORMAT_BGRA8888')
register('PIXELTYPE_PACKED32', 'SDL_PIXELTYPE_PACKED32')
register('PACKEDORDER_BGRA', 'SDL_PACKEDORDER_BGRA')
register('PACKEDLAYOUT_8888', 'SDL_PACKEDLAYOUT_8888')
register('PIXELFORMAT_ARGB2101010', 'SDL_PIXELFORMAT_ARGB2101010')
register('PIXELTYPE_PACKED32', 'SDL_PIXELTYPE_PACKED32')
register('PACKEDORDER_ARGB', 'SDL_PACKEDORDER_ARGB')
register('PACKEDLAYOUT_2101010', 'SDL_PACKEDLAYOUT_2101010')
register('PIXELFORMAT_YV12', 'SDL_PIXELFORMAT_YV12')
register('PIXELFORMAT_IYUV', 'SDL_PIXELFORMAT_IYUV')
register('PIXELFORMAT_YUY2', 'SDL_PIXELFORMAT_YUY2')
register('PIXELFORMAT_UYVY', 'SDL_PIXELFORMAT_UYVY')
register('PIXELFORMAT_YVYU', 'SDL_PIXELFORMAT_YVYU')
register('BLENDMODE_NONE', 'SDL_BLENDMODE_NONE')
register('BLENDMODE_BLEND', 'SDL_BLENDMODE_BLEND')
register('BLENDMODE_ADD', 'SDL_BLENDMODE_ADD')
register('BLENDMODE_MOD', 'SDL_BLENDMODE_MOD')
register('WINDOW_FULLSCREEN', 'SDL_WINDOW_FULLSCREEN')
register('WINDOW_OPENGL', 'SDL_WINDOW_OPENGL')
register('WINDOW_SHOWN', 'SDL_WINDOW_SHOWN')
register('WINDOW_HIDDEN', 'SDL_WINDOW_HIDDEN')
register('WINDOW_BORDERLESS', 'SDL_WINDOW_BORDERLESS')
register('WINDOW_RESIZABLE', 'SDL_WINDOW_RESIZABLE')
register('WINDOW_MINIMIZED', 'SDL_WINDOW_MINIMIZED')
register('WINDOW_MAXIMIZED', 'SDL_WINDOW_MAXIMIZED')
register('WINDOW_INPUT_GRABBED', 'SDL_WINDOW_INPUT_GRABBED')
register('WINDOW_INPUT_FOCUS', 'SDL_WINDOW_INPUT_FOCUS')
register('WINDOW_MOUSE_FOCUS', 'SDL_WINDOW_MOUSE_FOCUS')
register('WINDOW_FULLSCREEN_DESKTOP', 'SDL_WINDOW_FULLSCREEN_DESKTOP')
register('WINDOW_FULLSCREEN', 'SDL_WINDOW_FULLSCREEN')
register('WINDOW_FOREIGN', 'SDL_WINDOW_FOREIGN')
register('WINDOWEVENT_NONE', 'SDL_WINDOWEVENT_NONE')
register('WINDOWEVENT_SHOWN', 'SDL_WINDOWEVENT_SHOWN')
register('WINDOWEVENT_HIDDEN', 'SDL_WINDOWEVENT_HIDDEN')
register('WINDOWEVENT_EXPOSED', 'SDL_WINDOWEVENT_EXPOSED')
register('WINDOWEVENT_MOVED', 'SDL_WINDOWEVENT_MOVED')
register('WINDOWEVENT_RESIZED', 'SDL_WINDOWEVENT_RESIZED')
register('WINDOWEVENT_SIZE_CHANGED', 'SDL_WINDOWEVENT_SIZE_CHANGED')
register('WINDOWEVENT_MINIMIZED', 'SDL_WINDOWEVENT_MINIMIZED')
register('WINDOWEVENT_MAXIMIZED', 'SDL_WINDOWEVENT_MAXIMIZED')
register('WINDOWEVENT_RESTORED', 'SDL_WINDOWEVENT_RESTORED')
register('WINDOWEVENT_ENTER', 'SDL_WINDOWEVENT_ENTER')
register('WINDOWEVENT_LEAVE', 'SDL_WINDOWEVENT_LEAVE')
register('WINDOWEVENT_FOCUS_GAINED', 'SDL_WINDOWEVENT_FOCUS_GAINED')
register('WINDOWEVENT_FOCUS_LOST', 'SDL_WINDOWEVENT_FOCUS_LOST')
register('WINDOWEVENT_CLOSE', 'SDL_WINDOWEVENT_CLOSE')
register('GL_RED_SIZE', 'SDL_GL_RED_SIZE')
register('GL_GREEN_SIZE', 'SDL_GL_GREEN_SIZE')
register('GL_BLUE_SIZE', 'SDL_GL_BLUE_SIZE')
register('GL_ALPHA_SIZE', 'SDL_GL_ALPHA_SIZE')
register('GL_BUFFER_SIZE', 'SDL_GL_BUFFER_SIZE')
register('GL_DOUBLEBUFFER', 'SDL_GL_DOUBLEBUFFER')
register('GL_DEPTH_SIZE', 'SDL_GL_DEPTH_SIZE')
register('GL_STENCIL_SIZE', 'SDL_GL_STENCIL_SIZE')
register('GL_ACCUM_RED_SIZE', 'SDL_GL_ACCUM_RED_SIZE')
register('GL_ACCUM_GREEN_SIZE', 'SDL_GL_ACCUM_GREEN_SIZE')
register('GL_ACCUM_BLUE_SIZE', 'SDL_GL_ACCUM_BLUE_SIZE')
register('GL_ACCUM_ALPHA_SIZE', 'SDL_GL_ACCUM_ALPHA_SIZE')
register('GL_STEREO', 'SDL_GL_STEREO')
register('GL_MULTISAMPLEBUFFERS', 'SDL_GL_MULTISAMPLEBUFFERS')
register('GL_MULTISAMPLESAMPLES', 'SDL_GL_MULTISAMPLESAMPLES')
register('GL_ACCELERATED_VISUAL', 'SDL_GL_ACCELERATED_VISUAL')
register('GL_RETAINED_BACKING', 'SDL_GL_RETAINED_BACKING')
register('GL_CONTEXT_MAJOR_VERSION', 'SDL_GL_CONTEXT_MAJOR_VERSION')
register('GL_CONTEXT_MINOR_VERSION', 'SDL_GL_CONTEXT_MINOR_VERSION')
register('GL_CONTEXT_EGL', 'SDL_GL_CONTEXT_EGL')
register('GL_CONTEXT_FLAGS', 'SDL_GL_CONTEXT_FLAGS')
register('GL_CONTEXT_PROFILE_MASK', 'SDL_GL_CONTEXT_PROFILE_MASK')
register('GL_SHARE_WITH_CURRENT_CONTEXT', 'SDL_GL_SHARE_WITH_CURRENT_CONTEXT')
register('GL_SHARE_WITH_CURRENT_CONTEXT', 'SDL_GL_SHARE_WITH_CURRENT_CONTEXT')
register('GL_FRAMEBUFFER_SRGB_CAPABLE', 'SDL_GL_FRAMEBUFFER_SRGB_CAPABLE')
register('GL_CONTEXT_PROFILE_COMPATIBILITY', 'SDL_GL_CONTEXT_PROFILE_COMPATIBILITY')
register('GL_CONTEXT_PROFILE_ES', 'SDL_GL_CONTEXT_PROFILE_ES')
register('GL_CONTEXT_DEBUG_FLAG', 'SDL_GL_CONTEXT_DEBUG_FLAG')
register('GL_CONTEXT_FORWARD_COMPATIBLE_FLAG', 'SDL_GL_CONTEXT_FORWARD_COMPATIBLE_FLAG')
register('GL_CONTEXT_ROBUST_ACCESS_FLAG', 'SDL_GL_CONTEXT_ROBUST_ACCESS_FLAG')
register('GL_CONTEXT_RESET_ISOLATION_FLAG', 'SDL_GL_CONTEXT_RESET_ISOLATION_FLAG')
register('SCANCODE_UNKNOWN', 'SDL_SCANCODE_UNKNOWN')
register('SCANCODE_A', 'SDL_SCANCODE_A')
register('SCANCODE_B', 'SDL_SCANCODE_B')
register('SCANCODE_C', 'SDL_SCANCODE_C')
register('SCANCODE_D', 'SDL_SCANCODE_D')
register('SCANCODE_E', 'SDL_SCANCODE_E')
register('SCANCODE_F', 'SDL_SCANCODE_F')
register('SCANCODE_G', 'SDL_SCANCODE_G')
register('SCANCODE_H', 'SDL_SCANCODE_H')
register('SCANCODE_I', 'SDL_SCANCODE_I')
register('SCANCODE_J', 'SDL_SCANCODE_J')
register('SCANCODE_K', 'SDL_SCANCODE_K')
register('SCANCODE_L', 'SDL_SCANCODE_L')
register('SCANCODE_M', 'SDL_SCANCODE_M')
register('SCANCODE_N', 'SDL_SCANCODE_N')
register('SCANCODE_O', 'SDL_SCANCODE_O')
register('SCANCODE_P', 'SDL_SCANCODE_P')
register('SCANCODE_Q', 'SDL_SCANCODE_Q')
register('SCANCODE_R', 'SDL_SCANCODE_R')
register('SCANCODE_S', 'SDL_SCANCODE_S')
register('SCANCODE_T', 'SDL_SCANCODE_T')
register('SCANCODE_U', 'SDL_SCANCODE_U')
register('SCANCODE_V', 'SDL_SCANCODE_V')
register('SCANCODE_W', 'SDL_SCANCODE_W')
register('SCANCODE_X', 'SDL_SCANCODE_X')
register('SCANCODE_Y', 'SDL_SCANCODE_Y')
register('SCANCODE_Z', 'SDL_SCANCODE_Z')
register('SCANCODE_1', 'SDL_SCANCODE_1')
register('SCANCODE_2', 'SDL_SCANCODE_2')
register('SCANCODE_3', 'SDL_SCANCODE_3')
register('SCANCODE_4', 'SDL_SCANCODE_4')
register('SCANCODE_5', 'SDL_SCANCODE_5')
register('SCANCODE_6', 'SDL_SCANCODE_6')
register('SCANCODE_7', 'SDL_SCANCODE_7')
register('SCANCODE_8', 'SDL_SCANCODE_8')
register('SCANCODE_9', 'SDL_SCANCODE_9')
register('SCANCODE_0', 'SDL_SCANCODE_0')
register('SCANCODE_RETURN', 'SDL_SCANCODE_RETURN')
register('SCANCODE_ESCAPE', 'SDL_SCANCODE_ESCAPE')
register('SCANCODE_BACKSPACE', 'SDL_SCANCODE_BACKSPACE')
register('SCANCODE_TAB', 'SDL_SCANCODE_TAB')
register('SCANCODE_SPACE', 'SDL_SCANCODE_SPACE')
register('SCANCODE_MINUS', 'SDL_SCANCODE_MINUS')
register('SCANCODE_EQUALS', 'SDL_SCANCODE_EQUALS')
register('SCANCODE_LEFTBRACKET', 'SDL_SCANCODE_LEFTBRACKET')
register('SCANCODE_RIGHTBRACKET', 'SDL_SCANCODE_RIGHTBRACKET')
register('SCANCODE_BACKSLASH', 'SDL_SCANCODE_BACKSLASH')
register('SCANCODE_NONUSHASH', 'SDL_SCANCODE_NONUSHASH')
register('SCANCODE_SEMICOLON', 'SDL_SCANCODE_SEMICOLON')
register('SCANCODE_APOSTROPHE', 'SDL_SCANCODE_APOSTROPHE')
register('SCANCODE_GRAVE', 'SDL_SCANCODE_GRAVE')
register('SCANCODE_COMMA', 'SDL_SCANCODE_COMMA')
register('SCANCODE_PERIOD', 'SDL_SCANCODE_PERIOD')
register('SCANCODE_SLASH', 'SDL_SCANCODE_SLASH')
register('SCANCODE_CAPSLOCK', 'SDL_SCANCODE_CAPSLOCK')
register('SCANCODE_F1', 'SDL_SCANCODE_F1')
register('SCANCODE_F2', 'SDL_SCANCODE_F2')
register('SCANCODE_F3', 'SDL_SCANCODE_F3')
register('SCANCODE_F4', 'SDL_SCANCODE_F4')
register('SCANCODE_F5', 'SDL_SCANCODE_F5')
register('SCANCODE_F6', 'SDL_SCANCODE_F6')
register('SCANCODE_F7', 'SDL_SCANCODE_F7')
register('SCANCODE_F8', 'SDL_SCANCODE_F8')
register('SCANCODE_F9', 'SDL_SCANCODE_F9')
register('SCANCODE_F10', 'SDL_SCANCODE_F10')
register('SCANCODE_F11', 'SDL_SCANCODE_F11')
register('SCANCODE_F12', 'SDL_SCANCODE_F12')
register('SCANCODE_PRINTSCREEN', 'SDL_SCANCODE_PRINTSCREEN')
register('SCANCODE_SCROLLLOCK', 'SDL_SCANCODE_SCROLLLOCK')
register('SCANCODE_PAUSE', 'SDL_SCANCODE_PAUSE')
register('SCANCODE_INSERT', 'SDL_SCANCODE_INSERT')
register('SCANCODE_HOME', 'SDL_SCANCODE_HOME')
register('SCANCODE_PAGEUP', 'SDL_SCANCODE_PAGEUP')
register('SCANCODE_DELETE', 'SDL_SCANCODE_DELETE')
register('SCANCODE_END', 'SDL_SCANCODE_END')
register('SCANCODE_PAGEDOWN', 'SDL_SCANCODE_PAGEDOWN')
register('SCANCODE_RIGHT', 'SDL_SCANCODE_RIGHT')
register('SCANCODE_LEFT', 'SDL_SCANCODE_LEFT')
register('SCANCODE_DOWN', 'SDL_SCANCODE_DOWN')
register('SCANCODE_UP', 'SDL_SCANCODE_UP')
register('SCANCODE_NUMLOCKCLEAR', 'SDL_SCANCODE_NUMLOCKCLEAR')
register('SCANCODE_KP_DIVIDE', 'SDL_SCANCODE_KP_DIVIDE')
register('SCANCODE_KP_MULTIPLY', 'SDL_SCANCODE_KP_MULTIPLY')
register('SCANCODE_KP_MINUS', 'SDL_SCANCODE_KP_MINUS')
register('SCANCODE_KP_PLUS', 'SDL_SCANCODE_KP_PLUS')
register('SCANCODE_KP_ENTER', 'SDL_SCANCODE_KP_ENTER')
register('SCANCODE_KP_1', 'SDL_SCANCODE_KP_1')
register('SCANCODE_KP_2', 'SDL_SCANCODE_KP_2')
register('SCANCODE_KP_3', 'SDL_SCANCODE_KP_3')
register('SCANCODE_KP_4', 'SDL_SCANCODE_KP_4')
register('SCANCODE_KP_5', 'SDL_SCANCODE_KP_5')
register('SCANCODE_KP_6', 'SDL_SCANCODE_KP_6')
register('SCANCODE_KP_7', 'SDL_SCANCODE_KP_7')
register('SCANCODE_KP_8', 'SDL_SCANCODE_KP_8')
register('SCANCODE_KP_9', 'SDL_SCANCODE_KP_9')
register('SCANCODE_KP_0', 'SDL_SCANCODE_KP_0')
register('SCANCODE_KP_PERIOD', 'SDL_SCANCODE_KP_PERIOD')
register('SCANCODE_NONUSBACKSLASH', 'SDL_SCANCODE_NONUSBACKSLASH')
register('SCANCODE_APPLICATION', 'SDL_SCANCODE_APPLICATION')
register('SCANCODE_POWER', 'SDL_SCANCODE_POWER')
register('SCANCODE_KP_EQUALS', 'SDL_SCANCODE_KP_EQUALS')
register('SCANCODE_F13', 'SDL_SCANCODE_F13')
register('SCANCODE_F14', 'SDL_SCANCODE_F14')
register('SCANCODE_F15', 'SDL_SCANCODE_F15')
register('SCANCODE_F16', 'SDL_SCANCODE_F16')
register('SCANCODE_F17', 'SDL_SCANCODE_F17')
register('SCANCODE_F18', 'SDL_SCANCODE_F18')
register('SCANCODE_F19', 'SDL_SCANCODE_F19')
register('SCANCODE_F20', 'SDL_SCANCODE_F20')
register('SCANCODE_F21', 'SDL_SCANCODE_F21')
register('SCANCODE_F22', 'SDL_SCANCODE_F22')
register('SCANCODE_F23', 'SDL_SCANCODE_F23')
register('SCANCODE_F24', 'SDL_SCANCODE_F24')
register('SCANCODE_EXECUTE', 'SDL_SCANCODE_EXECUTE')
register('SCANCODE_HELP', 'SDL_SCANCODE_HELP')
register('SCANCODE_MENU', 'SDL_SCANCODE_MENU')
register('SCANCODE_SELECT', 'SDL_SCANCODE_SELECT')
register('SCANCODE_STOP', 'SDL_SCANCODE_STOP')
register('SCANCODE_AGAIN', 'SDL_SCANCODE_AGAIN')
register('SCANCODE_UNDO', 'SDL_SCANCODE_UNDO')
register('SCANCODE_CUT', 'SDL_SCANCODE_CUT')
register('SCANCODE_COPY', 'SDL_SCANCODE_COPY')
register('SCANCODE_PASTE', 'SDL_SCANCODE_PASTE')
register('SCANCODE_FIND', 'SDL_SCANCODE_FIND')
register('SCANCODE_MUTE', 'SDL_SCANCODE_MUTE')
register('SCANCODE_VOLUMEUP', 'SDL_SCANCODE_VOLUMEUP')
register('SCANCODE_VOLUMEDOWN', 'SDL_SCANCODE_VOLUMEDOWN')
register('SCANCODE_KP_COMMA', 'SDL_SCANCODE_KP_COMMA')
register('SCANCODE_KP_EQUALSAS400', 'SDL_SCANCODE_KP_EQUALSAS400')
register('SCANCODE_INTERNATIONAL1', 'SDL_SCANCODE_INTERNATIONAL1')
register('SCANCODE_INTERNATIONAL2', 'SDL_SCANCODE_INTERNATIONAL2')
register('SCANCODE_INTERNATIONAL3', 'SDL_SCANCODE_INTERNATIONAL3')
register('SCANCODE_INTERNATIONAL4', 'SDL_SCANCODE_INTERNATIONAL4')
register('SCANCODE_INTERNATIONAL5', 'SDL_SCANCODE_INTERNATIONAL5')
register('SCANCODE_INTERNATIONAL6', 'SDL_SCANCODE_INTERNATIONAL6')
register('SCANCODE_INTERNATIONAL7', 'SDL_SCANCODE_INTERNATIONAL7')
register('SCANCODE_INTERNATIONAL8', 'SDL_SCANCODE_INTERNATIONAL8')
register('SCANCODE_INTERNATIONAL9', 'SDL_SCANCODE_INTERNATIONAL9')
register('SCANCODE_LANG1', 'SDL_SCANCODE_LANG1')
register('SCANCODE_LANG2', 'SDL_SCANCODE_LANG2')
register('SCANCODE_LANG3', 'SDL_SCANCODE_LANG3')
register('SCANCODE_LANG4', 'SDL_SCANCODE_LANG4')
register('SCANCODE_LANG5', 'SDL_SCANCODE_LANG5')
register('SCANCODE_LANG6', 'SDL_SCANCODE_LANG6')
register('SCANCODE_LANG7', 'SDL_SCANCODE_LANG7')
register('SCANCODE_LANG8', 'SDL_SCANCODE_LANG8')
register('SCANCODE_LANG9', 'SDL_SCANCODE_LANG9')
register('SCANCODE_ALTERASE', 'SDL_SCANCODE_ALTERASE')
register('SCANCODE_SYSREQ', 'SDL_SCANCODE_SYSREQ')
register('SCANCODE_CANCEL', 'SDL_SCANCODE_CANCEL')
register('SCANCODE_CLEAR', 'SDL_SCANCODE_CLEAR')
register('SCANCODE_PRIOR', 'SDL_SCANCODE_PRIOR')
register('SCANCODE_RETURN2', 'SDL_SCANCODE_RETURN2')
register('SCANCODE_SEPARATOR', 'SDL_SCANCODE_SEPARATOR')
register('SCANCODE_OUT', 'SDL_SCANCODE_OUT')
register('SCANCODE_OPER', 'SDL_SCANCODE_OPER')
register('SCANCODE_CLEARAGAIN', 'SDL_SCANCODE_CLEARAGAIN')
register('SCANCODE_CRSEL', 'SDL_SCANCODE_CRSEL')
register('SCANCODE_EXSEL', 'SDL_SCANCODE_EXSEL')
register('SCANCODE_KP_00', 'SDL_SCANCODE_KP_00')
register('SCANCODE_KP_000', 'SDL_SCANCODE_KP_000')
register('SCANCODE_THOUSANDSSEPARATOR', 'SDL_SCANCODE_THOUSANDSSEPARATOR')
register('SCANCODE_DECIMALSEPARATOR', 'SDL_SCANCODE_DECIMALSEPARATOR')
register('SCANCODE_CURRENCYUNIT', 'SDL_SCANCODE_CURRENCYUNIT')
register('SCANCODE_CURRENCYSUBUNIT', 'SDL_SCANCODE_CURRENCYSUBUNIT')
register('SCANCODE_KP_LEFTPAREN', 'SDL_SCANCODE_KP_LEFTPAREN')
register('SCANCODE_KP_RIGHTPAREN', 'SDL_SCANCODE_KP_RIGHTPAREN')
register('SCANCODE_KP_LEFTBRACE', 'SDL_SCANCODE_KP_LEFTBRACE')
register('SCANCODE_KP_RIGHTBRACE', 'SDL_SCANCODE_KP_RIGHTBRACE')
register('SCANCODE_KP_TAB', 'SDL_SCANCODE_KP_TAB')
register('SCANCODE_KP_BACKSPACE', 'SDL_SCANCODE_KP_BACKSPACE')
register('SCANCODE_KP_A', 'SDL_SCANCODE_KP_A')
register('SCANCODE_KP_B', 'SDL_SCANCODE_KP_B')
register('SCANCODE_KP_C', 'SDL_SCANCODE_KP_C')
register('SCANCODE_KP_D', 'SDL_SCANCODE_KP_D')
register('SCANCODE_KP_E', 'SDL_SCANCODE_KP_E')
register('SCANCODE_KP_F', 'SDL_SCANCODE_KP_F')
register('SCANCODE_KP_XOR', 'SDL_SCANCODE_KP_XOR')
register('SCANCODE_KP_POWER', 'SDL_SCANCODE_KP_POWER')
register('SCANCODE_KP_PERCENT', 'SDL_SCANCODE_KP_PERCENT')
register('SCANCODE_KP_LESS', 'SDL_SCANCODE_KP_LESS')
register('SCANCODE_KP_GREATER', 'SDL_SCANCODE_KP_GREATER')
register('SCANCODE_KP_AMPERSAND', 'SDL_SCANCODE_KP_AMPERSAND')
register('SCANCODE_KP_DBLAMPERSAND', 'SDL_SCANCODE_KP_DBLAMPERSAND')
register('SCANCODE_KP_VERTICALBAR', 'SDL_SCANCODE_KP_VERTICALBAR')
register('SCANCODE_KP_DBLVERTICALBAR', 'SDL_SCANCODE_KP_DBLVERTICALBAR')
register('SCANCODE_KP_COLON', 'SDL_SCANCODE_KP_COLON')
register('SCANCODE_KP_HASH', 'SDL_SCANCODE_KP_HASH')
register('SCANCODE_KP_SPACE', 'SDL_SCANCODE_KP_SPACE')
register('SCANCODE_KP_AT', 'SDL_SCANCODE_KP_AT')
register('SCANCODE_KP_EXCLAM', 'SDL_SCANCODE_KP_EXCLAM')
register('SCANCODE_KP_MEMSTORE', 'SDL_SCANCODE_KP_MEMSTORE')
register('SCANCODE_KP_MEMRECALL', 'SDL_SCANCODE_KP_MEMRECALL')
register('SCANCODE_KP_MEMCLEAR', 'SDL_SCANCODE_KP_MEMCLEAR')
register('SCANCODE_KP_MEMADD', 'SDL_SCANCODE_KP_MEMADD')
register('SCANCODE_KP_MEMSUBTRACT', 'SDL_SCANCODE_KP_MEMSUBTRACT')
register('SCANCODE_KP_MEMMULTIPLY', 'SDL_SCANCODE_KP_MEMMULTIPLY')
register('SCANCODE_KP_MEMDIVIDE', 'SDL_SCANCODE_KP_MEMDIVIDE')
register('SCANCODE_KP_PLUSMINUS', 'SDL_SCANCODE_KP_PLUSMINUS')
register('SCANCODE_KP_CLEAR', 'SDL_SCANCODE_KP_CLEAR')
register('SCANCODE_KP_CLEARENTRY', 'SDL_SCANCODE_KP_CLEARENTRY')
register('SCANCODE_KP_BINARY', 'SDL_SCANCODE_KP_BINARY')
register('SCANCODE_KP_OCTAL', 'SDL_SCANCODE_KP_OCTAL')
register('SCANCODE_KP_DECIMAL', 'SDL_SCANCODE_KP_DECIMAL')
register('SCANCODE_KP_HEXADECIMAL', 'SDL_SCANCODE_KP_HEXADECIMAL')
register('SCANCODE_LCTRL', 'SDL_SCANCODE_LCTRL')
register('SCANCODE_LSHIFT', 'SDL_SCANCODE_LSHIFT')
register('SCANCODE_LALT', 'SDL_SCANCODE_LALT')
register('SCANCODE_LGUI', 'SDL_SCANCODE_LGUI')
register('SCANCODE_RCTRL', 'SDL_SCANCODE_RCTRL')
register('SCANCODE_RSHIFT', 'SDL_SCANCODE_RSHIFT')
register('SCANCODE_RALT', 'SDL_SCANCODE_RALT')
register('SCANCODE_RGUI', 'SDL_SCANCODE_RGUI')
register('SCANCODE_MODE', 'SDL_SCANCODE_MODE')
register('SCANCODE_AUDIONEXT', 'SDL_SCANCODE_AUDIONEXT')
register('SCANCODE_AUDIOPREV', 'SDL_SCANCODE_AUDIOPREV')
register('SCANCODE_AUDIOSTOP', 'SDL_SCANCODE_AUDIOSTOP')
register('SCANCODE_AUDIOPLAY', 'SDL_SCANCODE_AUDIOPLAY')
register('SCANCODE_AUDIOMUTE', 'SDL_SCANCODE_AUDIOMUTE')
register('SCANCODE_MEDIASELECT', 'SDL_SCANCODE_MEDIASELECT')
register('SCANCODE_WWW', 'SDL_SCANCODE_WWW')
register('SCANCODE_MAIL', 'SDL_SCANCODE_MAIL')
register('SCANCODE_CALCULATOR', 'SDL_SCANCODE_CALCULATOR')
register('SCANCODE_COMPUTER', 'SDL_SCANCODE_COMPUTER')
register('SCANCODE_AC_SEARCH', 'SDL_SCANCODE_AC_SEARCH')
register('SCANCODE_AC_HOME', 'SDL_SCANCODE_AC_HOME')
register('SCANCODE_AC_BACK', 'SDL_SCANCODE_AC_BACK')
register('SCANCODE_AC_FORWARD', 'SDL_SCANCODE_AC_FORWARD')
register('SCANCODE_AC_STOP', 'SDL_SCANCODE_AC_STOP')
register('SCANCODE_AC_REFRESH', 'SDL_SCANCODE_AC_REFRESH')
register('SCANCODE_AC_BOOKMARKS', 'SDL_SCANCODE_AC_BOOKMARKS')
register('SCANCODE_BRIGHTNESSDOWN', 'SDL_SCANCODE_BRIGHTNESSDOWN')
register('SCANCODE_BRIGHTNESSUP', 'SDL_SCANCODE_BRIGHTNESSUP')
register('SCANCODE_DISPLAYSWITCH', 'SDL_SCANCODE_DISPLAYSWITCH')
register('SCANCODE_KBDILLUMTOGGLE', 'SDL_SCANCODE_KBDILLUMTOGGLE')
register('SCANCODE_KBDILLUMDOWN', 'SDL_SCANCODE_KBDILLUMDOWN')
register('SCANCODE_KBDILLUMUP', 'SDL_SCANCODE_KBDILLUMUP')
register('SCANCODE_EJECT', 'SDL_SCANCODE_EJECT')
register('SCANCODE_SLEEP', 'SDL_SCANCODE_SLEEP')
register('SCANCODE_APP1', 'SDL_SCANCODE_APP1')
register('SCANCODE_APP2', 'SDL_SCANCODE_APP2')
register('NUM_SCANCODES', 'SDL_NUM_SCANCODES')
register('SCANCODE_CAPSLOCK', 'SDL_SCANCODE_CAPSLOCK')
register('SCANCODE_F1', 'SDL_SCANCODE_F1')
register('SCANCODE_F2', 'SDL_SCANCODE_F2')
register('SCANCODE_F3', 'SDL_SCANCODE_F3')
register('SCANCODE_F4', 'SDL_SCANCODE_F4')
register('SCANCODE_F5', 'SDL_SCANCODE_F5')
register('SCANCODE_F6', 'SDL_SCANCODE_F6')
register('SCANCODE_F7', 'SDL_SCANCODE_F7')
register('SCANCODE_F8', 'SDL_SCANCODE_F8')
register('SCANCODE_F9', 'SDL_SCANCODE_F9')
register('SCANCODE_F10', 'SDL_SCANCODE_F10')
register('SCANCODE_F11', 'SDL_SCANCODE_F11')
register('SCANCODE_F12', 'SDL_SCANCODE_F12')
register('SCANCODE_PRINTSCREEN', 'SDL_SCANCODE_PRINTSCREEN')
register('SCANCODE_SCROLLLOCK', 'SDL_SCANCODE_SCROLLLOCK')
register('SCANCODE_PAUSE', 'SDL_SCANCODE_PAUSE')
register('SCANCODE_INSERT', 'SDL_SCANCODE_INSERT')
register('SCANCODE_HOME', 'SDL_SCANCODE_HOME')
register('SCANCODE_PAGEUP', 'SDL_SCANCODE_PAGEUP')
register('SCANCODE_END', 'SDL_SCANCODE_END')
register('SCANCODE_PAGEDOWN', 'SDL_SCANCODE_PAGEDOWN')
register('SCANCODE_RIGHT', 'SDL_SCANCODE_RIGHT')
register('SCANCODE_LEFT', 'SDL_SCANCODE_LEFT')
register('SCANCODE_DOWN', 'SDL_SCANCODE_DOWN')
register('SCANCODE_UP', 'SDL_SCANCODE_UP')
register('SCANCODE_NUMLOCKCLEAR', 'SDL_SCANCODE_NUMLOCKCLEAR')
register('SCANCODE_KP_DIVIDE', 'SDL_SCANCODE_KP_DIVIDE')
register('SCANCODE_KP_MULTIPLY', 'SDL_SCANCODE_KP_MULTIPLY')
register('SCANCODE_KP_MINUS', 'SDL_SCANCODE_KP_MINUS')
register('SCANCODE_KP_PLUS', 'SDL_SCANCODE_KP_PLUS')
register('SCANCODE_KP_ENTER', 'SDL_SCANCODE_KP_ENTER')
register('SCANCODE_KP_1', 'SDL_SCANCODE_KP_1')
register('SCANCODE_KP_2', 'SDL_SCANCODE_KP_2')
register('SCANCODE_KP_3', 'SDL_SCANCODE_KP_3')
register('SCANCODE_KP_4', 'SDL_SCANCODE_KP_4')
register('SCANCODE_KP_5', 'SDL_SCANCODE_KP_5')
register('SCANCODE_KP_6', 'SDL_SCANCODE_KP_6')
register('SCANCODE_KP_7', 'SDL_SCANCODE_KP_7')
register('SCANCODE_KP_8', 'SDL_SCANCODE_KP_8')
register('SCANCODE_KP_9', 'SDL_SCANCODE_KP_9')
register('SCANCODE_KP_0', 'SDL_SCANCODE_KP_0')
register('SCANCODE_KP_PERIOD', 'SDL_SCANCODE_KP_PERIOD')
register('SCANCODE_APPLICATION', 'SDL_SCANCODE_APPLICATION')
register('SCANCODE_POWER', 'SDL_SCANCODE_POWER')
register('SCANCODE_KP_EQUALS', 'SDL_SCANCODE_KP_EQUALS')
register('SCANCODE_F13', 'SDL_SCANCODE_F13')
register('SCANCODE_F14', 'SDL_SCANCODE_F14')
register('SCANCODE_F15', 'SDL_SCANCODE_F15')
register('SCANCODE_F16', 'SDL_SCANCODE_F16')
register('SCANCODE_F17', 'SDL_SCANCODE_F17')
register('SCANCODE_F18', 'SDL_SCANCODE_F18')
register('SCANCODE_F19', 'SDL_SCANCODE_F19')
register('SCANCODE_F20', 'SDL_SCANCODE_F20')
register('SCANCODE_F21', 'SDL_SCANCODE_F21')
register('SCANCODE_F22', 'SDL_SCANCODE_F22')
register('SCANCODE_F23', 'SDL_SCANCODE_F23')
register('SCANCODE_F24', 'SDL_SCANCODE_F24')
register('SCANCODE_EXECUTE', 'SDL_SCANCODE_EXECUTE')
register('SCANCODE_HELP', 'SDL_SCANCODE_HELP')
register('SCANCODE_MENU', 'SDL_SCANCODE_MENU')
register('SCANCODE_SELECT', 'SDL_SCANCODE_SELECT')
register('SCANCODE_STOP', 'SDL_SCANCODE_STOP')
register('SCANCODE_AGAIN', 'SDL_SCANCODE_AGAIN')
register('SCANCODE_UNDO', 'SDL_SCANCODE_UNDO')
register('SCANCODE_CUT', 'SDL_SCANCODE_CUT')
register('SCANCODE_COPY', 'SDL_SCANCODE_COPY')
register('SCANCODE_PASTE', 'SDL_SCANCODE_PASTE')
register('SCANCODE_FIND', 'SDL_SCANCODE_FIND')
register('SCANCODE_MUTE', 'SDL_SCANCODE_MUTE')
register('SCANCODE_VOLUMEUP', 'SDL_SCANCODE_VOLUMEUP')
register('SCANCODE_VOLUMEDOWN', 'SDL_SCANCODE_VOLUMEDOWN')
register('SCANCODE_KP_COMMA', 'SDL_SCANCODE_KP_COMMA')
register('SCANCODE_KP_EQUALSAS400', 'SDL_SCANCODE_KP_EQUALSAS400')
register('SCANCODE_ALTERASE', 'SDL_SCANCODE_ALTERASE')
register('SCANCODE_SYSREQ', 'SDL_SCANCODE_SYSREQ')
register('SCANCODE_CANCEL', 'SDL_SCANCODE_CANCEL')
register('SCANCODE_CLEAR', 'SDL_SCANCODE_CLEAR')
register('SCANCODE_PRIOR', 'SDL_SCANCODE_PRIOR')
register('SCANCODE_RETURN2', 'SDL_SCANCODE_RETURN2')
register('SCANCODE_SEPARATOR', 'SDL_SCANCODE_SEPARATOR')
register('SCANCODE_OUT', 'SDL_SCANCODE_OUT')
register('SCANCODE_OPER', 'SDL_SCANCODE_OPER')
register('SCANCODE_CLEARAGAIN', 'SDL_SCANCODE_CLEARAGAIN')
register('SCANCODE_CRSEL', 'SDL_SCANCODE_CRSEL')
register('SCANCODE_EXSEL', 'SDL_SCANCODE_EXSEL')
register('SCANCODE_KP_00', 'SDL_SCANCODE_KP_00')
register('SCANCODE_KP_000', 'SDL_SCANCODE_KP_000')
register('SCANCODE_THOUSANDSSEPARATOR', 'SDL_SCANCODE_THOUSANDSSEPARATOR')
register('SCANCODE_DECIMALSEPARATOR', 'SDL_SCANCODE_DECIMALSEPARATOR')
register('SCANCODE_CURRENCYUNIT', 'SDL_SCANCODE_CURRENCYUNIT')
register('SCANCODE_CURRENCYSUBUNIT', 'SDL_SCANCODE_CURRENCYSUBUNIT')
register('SCANCODE_KP_LEFTPAREN', 'SDL_SCANCODE_KP_LEFTPAREN')
register('SCANCODE_KP_RIGHTPAREN', 'SDL_SCANCODE_KP_RIGHTPAREN')
register('SCANCODE_KP_LEFTBRACE', 'SDL_SCANCODE_KP_LEFTBRACE')
register('SCANCODE_KP_RIGHTBRACE', 'SDL_SCANCODE_KP_RIGHTBRACE')
register('SCANCODE_KP_TAB', 'SDL_SCANCODE_KP_TAB')
register('SCANCODE_KP_BACKSPACE', 'SDL_SCANCODE_KP_BACKSPACE')
register('SCANCODE_KP_A', 'SDL_SCANCODE_KP_A')
register('SCANCODE_KP_B', 'SDL_SCANCODE_KP_B')
register('SCANCODE_KP_C', 'SDL_SCANCODE_KP_C')
register('SCANCODE_KP_D', 'SDL_SCANCODE_KP_D')
register('SCANCODE_KP_E', 'SDL_SCANCODE_KP_E')
register('SCANCODE_KP_F', 'SDL_SCANCODE_KP_F')
register('SCANCODE_KP_XOR', 'SDL_SCANCODE_KP_XOR')
register('SCANCODE_KP_POWER', 'SDL_SCANCODE_KP_POWER')
register('SCANCODE_KP_PERCENT', 'SDL_SCANCODE_KP_PERCENT')
register('SCANCODE_KP_LESS', 'SDL_SCANCODE_KP_LESS')
register('SCANCODE_KP_GREATER', 'SDL_SCANCODE_KP_GREATER')
register('SCANCODE_KP_AMPERSAND', 'SDL_SCANCODE_KP_AMPERSAND')
register('SCANCODE_KP_DBLAMPERSAND', 'SDL_SCANCODE_KP_DBLAMPERSAND')
register('SCANCODE_KP_VERTICALBAR', 'SDL_SCANCODE_KP_VERTICALBAR')
register('SCANCODE_KP_DBLVERTICALBAR', 'SDL_SCANCODE_KP_DBLVERTICALBAR')
register('SCANCODE_KP_COLON', 'SDL_SCANCODE_KP_COLON')
register('SCANCODE_KP_HASH', 'SDL_SCANCODE_KP_HASH')
register('SCANCODE_KP_SPACE', 'SDL_SCANCODE_KP_SPACE')
register('SCANCODE_KP_AT', 'SDL_SCANCODE_KP_AT')
register('SCANCODE_KP_EXCLAM', 'SDL_SCANCODE_KP_EXCLAM')
register('SCANCODE_KP_MEMSTORE', 'SDL_SCANCODE_KP_MEMSTORE')
register('SCANCODE_KP_MEMRECALL', 'SDL_SCANCODE_KP_MEMRECALL')
register('SCANCODE_KP_MEMCLEAR', 'SDL_SCANCODE_KP_MEMCLEAR')
register('SCANCODE_KP_MEMADD', 'SDL_SCANCODE_KP_MEMADD')
register('SCANCODE_KP_MEMSUBTRACT', 'SDL_SCANCODE_KP_MEMSUBTRACT')
register('SCANCODE_KP_MEMMULTIPLY', 'SDL_SCANCODE_KP_MEMMULTIPLY')
register('SCANCODE_KP_MEMDIVIDE', 'SDL_SCANCODE_KP_MEMDIVIDE')
register('SCANCODE_KP_PLUSMINUS', 'SDL_SCANCODE_KP_PLUSMINUS')
register('SCANCODE_KP_CLEAR', 'SDL_SCANCODE_KP_CLEAR')
register('SCANCODE_KP_CLEARENTRY', 'SDL_SCANCODE_KP_CLEARENTRY')
register('SCANCODE_KP_BINARY', 'SDL_SCANCODE_KP_BINARY')
register('SCANCODE_KP_OCTAL', 'SDL_SCANCODE_KP_OCTAL')
register('SCANCODE_KP_DECIMAL', 'SDL_SCANCODE_KP_DECIMAL')
register('SCANCODE_KP_HEXADECIMAL', 'SDL_SCANCODE_KP_HEXADECIMAL')
register('SCANCODE_LCTRL', 'SDL_SCANCODE_LCTRL')
register('SCANCODE_LSHIFT', 'SDL_SCANCODE_LSHIFT')
register('SCANCODE_LALT', 'SDL_SCANCODE_LALT')
register('SCANCODE_LGUI', 'SDL_SCANCODE_LGUI')
register('SCANCODE_RCTRL', 'SDL_SCANCODE_RCTRL')
register('SCANCODE_RSHIFT', 'SDL_SCANCODE_RSHIFT')
register('SCANCODE_RALT', 'SDL_SCANCODE_RALT')
register('SCANCODE_RGUI', 'SDL_SCANCODE_RGUI')
register('SCANCODE_MODE', 'SDL_SCANCODE_MODE')
register('SCANCODE_AUDIONEXT', 'SDL_SCANCODE_AUDIONEXT')
register('SCANCODE_AUDIOPREV', 'SDL_SCANCODE_AUDIOPREV')
register('SCANCODE_AUDIOSTOP', 'SDL_SCANCODE_AUDIOSTOP')
register('SCANCODE_AUDIOPLAY', 'SDL_SCANCODE_AUDIOPLAY')
register('SCANCODE_AUDIOMUTE', 'SDL_SCANCODE_AUDIOMUTE')
register('SCANCODE_MEDIASELECT', 'SDL_SCANCODE_MEDIASELECT')
register('SCANCODE_WWW', 'SDL_SCANCODE_WWW')
register('SCANCODE_MAIL', 'SDL_SCANCODE_MAIL')
register('SCANCODE_CALCULATOR', 'SDL_SCANCODE_CALCULATOR')
register('SCANCODE_COMPUTER', 'SDL_SCANCODE_COMPUTER')
register('SCANCODE_AC_SEARCH', 'SDL_SCANCODE_AC_SEARCH')
register('SCANCODE_AC_HOME', 'SDL_SCANCODE_AC_HOME')
register('SCANCODE_AC_BACK', 'SDL_SCANCODE_AC_BACK')
register('SCANCODE_AC_FORWARD', 'SDL_SCANCODE_AC_FORWARD')
register('SCANCODE_AC_STOP', 'SDL_SCANCODE_AC_STOP')
register('SCANCODE_AC_REFRESH', 'SDL_SCANCODE_AC_REFRESH')
register('SCANCODE_AC_BOOKMARKS', 'SDL_SCANCODE_AC_BOOKMARKS')
register('SCANCODE_BRIGHTNESSDOWN', 'SDL_SCANCODE_BRIGHTNESSDOWN')
register('SCANCODE_BRIGHTNESSUP', 'SDL_SCANCODE_BRIGHTNESSUP')
register('SCANCODE_DISPLAYSWITCH', 'SDL_SCANCODE_DISPLAYSWITCH')
register('SCANCODE_KBDILLUMTOGGLE', 'SDL_SCANCODE_KBDILLUMTOGGLE')
register('SCANCODE_KBDILLUMDOWN', 'SDL_SCANCODE_KBDILLUMDOWN')
register('SCANCODE_KBDILLUMUP', 'SDL_SCANCODE_KBDILLUMUP')
register('SCANCODE_EJECT', 'SDL_SCANCODE_EJECT')
register('SCANCODE_SLEEP', 'SDL_SCANCODE_SLEEP')
register('KMOD_NONE', 'SDL_KMOD_NONE')
register('KMOD_LSHIFT', 'SDL_KMOD_LSHIFT')
register('KMOD_RSHIFT', 'SDL_KMOD_RSHIFT')
register('KMOD_LCTRL', 'SDL_KMOD_LCTRL')
register('KMOD_RCTRL', 'SDL_KMOD_RCTRL')
register('KMOD_LALT', 'SDL_KMOD_LALT')
register('KMOD_RALT', 'SDL_KMOD_RALT')
register('KMOD_LGUI', 'SDL_KMOD_LGUI')
register('KMOD_RGUI', 'SDL_KMOD_RGUI')
register('KMOD_NUM', 'SDL_KMOD_NUM')
register('KMOD_CAPS', 'SDL_KMOD_CAPS')
register('KMOD_MODE', 'SDL_KMOD_MODE')
register('KMOD_RESERVED', 'SDL_KMOD_RESERVED')
register('SYSTEM_CURSOR_ARROW', 'SDL_SYSTEM_CURSOR_ARROW')
register('SYSTEM_CURSOR_IBEAM', 'SDL_SYSTEM_CURSOR_IBEAM')
register('SYSTEM_CURSOR_WAIT', 'SDL_SYSTEM_CURSOR_WAIT')
register('SYSTEM_CURSOR_CROSSHAIR', 'SDL_SYSTEM_CURSOR_CROSSHAIR')
register('SYSTEM_CURSOR_WAITARROW', 'SDL_SYSTEM_CURSOR_WAITARROW')
register('SYSTEM_CURSOR_SIZENWSE', 'SDL_SYSTEM_CURSOR_SIZENWSE')
register('SYSTEM_CURSOR_SIZENESW', 'SDL_SYSTEM_CURSOR_SIZENESW')
register('SYSTEM_CURSOR_SIZEWE', 'SDL_SYSTEM_CURSOR_SIZEWE')
register('SYSTEM_CURSOR_SIZENS', 'SDL_SYSTEM_CURSOR_SIZENS')
register('SYSTEM_CURSOR_SIZEALL', 'SDL_SYSTEM_CURSOR_SIZEALL')
register('SYSTEM_CURSOR_NO', 'SDL_SYSTEM_CURSOR_NO')
register('SYSTEM_CURSOR_HAND', 'SDL_SYSTEM_CURSOR_HAND')
register('NUM_SYSTEM_CURSORS', 'SDL_NUM_SYSTEM_CURSORS')
register('CONTROLLER_BINDTYPE_NONE', 'SDL_CONTROLLER_BINDTYPE_NONE')
register('CONTROLLER_BINDTYPE_BUTTON', 'SDL_CONTROLLER_BINDTYPE_BUTTON')
register('CONTROLLER_BINDTYPE_AXIS', 'SDL_CONTROLLER_BINDTYPE_AXIS')
register('CONTROLLER_BINDTYPE_HAT', 'SDL_CONTROLLER_BINDTYPE_HAT')
register('CONTROLLER_AXIS_INVALID', 'SDL_CONTROLLER_AXIS_INVALID')
register('CONTROLLER_AXIS_LEFTX', 'SDL_CONTROLLER_AXIS_LEFTX')
register('CONTROLLER_AXIS_LEFTY', 'SDL_CONTROLLER_AXIS_LEFTY')
register('CONTROLLER_AXIS_RIGHTX', 'SDL_CONTROLLER_AXIS_RIGHTX')
register('CONTROLLER_AXIS_RIGHTY', 'SDL_CONTROLLER_AXIS_RIGHTY')
register('CONTROLLER_AXIS_TRIGGERLEFT', 'SDL_CONTROLLER_AXIS_TRIGGERLEFT')
register('CONTROLLER_AXIS_TRIGGERRIGHT', 'SDL_CONTROLLER_AXIS_TRIGGERRIGHT')
register('CONTROLLER_AXIS_MAX', 'SDL_CONTROLLER_AXIS_MAX')
register('CONTROLLER_BUTTON_INVALID', 'SDL_CONTROLLER_BUTTON_INVALID')
register('CONTROLLER_BUTTON_A', 'SDL_CONTROLLER_BUTTON_A')
register('CONTROLLER_BUTTON_B', 'SDL_CONTROLLER_BUTTON_B')
register('CONTROLLER_BUTTON_X', 'SDL_CONTROLLER_BUTTON_X')
register('CONTROLLER_BUTTON_Y', 'SDL_CONTROLLER_BUTTON_Y')
register('CONTROLLER_BUTTON_BACK', 'SDL_CONTROLLER_BUTTON_BACK')
register('CONTROLLER_BUTTON_GUIDE', 'SDL_CONTROLLER_BUTTON_GUIDE')
register('CONTROLLER_BUTTON_START', 'SDL_CONTROLLER_BUTTON_START')
register('CONTROLLER_BUTTON_LEFTSTICK', 'SDL_CONTROLLER_BUTTON_LEFTSTICK')
register('CONTROLLER_BUTTON_RIGHTSTICK', 'SDL_CONTROLLER_BUTTON_RIGHTSTICK')
register('CONTROLLER_BUTTON_LEFTSHOULDER', 'SDL_CONTROLLER_BUTTON_LEFTSHOULDER')
register('CONTROLLER_BUTTON_RIGHTSHOULDER', 'SDL_CONTROLLER_BUTTON_RIGHTSHOULDER')
register('CONTROLLER_BUTTON_DPAD_UP', 'SDL_CONTROLLER_BUTTON_DPAD_UP')
register('CONTROLLER_BUTTON_DPAD_DOWN', 'SDL_CONTROLLER_BUTTON_DPAD_DOWN')
register('CONTROLLER_BUTTON_DPAD_LEFT', 'SDL_CONTROLLER_BUTTON_DPAD_LEFT')
register('CONTROLLER_BUTTON_DPAD_RIGHT', 'SDL_CONTROLLER_BUTTON_DPAD_RIGHT')
register('CONTROLLER_BUTTON_MAX', 'SDL_CONTROLLER_BUTTON_MAX')
register('FIRSTEVENT', 'SDL_FIRSTEVENT')
register('QUIT', 'SDL_QUIT')
register('APP_TERMINATING', 'SDL_APP_TERMINATING')
register('APP_LOWMEMORY', 'SDL_APP_LOWMEMORY')
register('APP_WILLENTERBACKGROUND', 'SDL_APP_WILLENTERBACKGROUND')
register('APP_DIDENTERBACKGROUND', 'SDL_APP_DIDENTERBACKGROUND')
register('APP_WILLENTERFOREGROUND', 'SDL_APP_WILLENTERFOREGROUND')
register('APP_DIDENTERFOREGROUND', 'SDL_APP_DIDENTERFOREGROUND')
register('WINDOWEVENT', 'SDL_WINDOWEVENT')
register('SYSWMEVENT', 'SDL_SYSWMEVENT')
register('KEYDOWN', 'SDL_KEYDOWN')
register('KEYUP', 'SDL_KEYUP')
register('TEXTEDITING', 'SDL_TEXTEDITING')
register('TEXTINPUT', 'SDL_TEXTINPUT')
register('MOUSEMOTION', 'SDL_MOUSEMOTION')
register('MOUSEBUTTONDOWN', 'SDL_MOUSEBUTTONDOWN')
register('MOUSEBUTTONUP', 'SDL_MOUSEBUTTONUP')
register('MOUSEWHEEL', 'SDL_MOUSEWHEEL')
register('JOYAXISMOTION', 'SDL_JOYAXISMOTION')
register('JOYBALLMOTION', 'SDL_JOYBALLMOTION')
register('JOYHATMOTION', 'SDL_JOYHATMOTION')
register('JOYBUTTONDOWN', 'SDL_JOYBUTTONDOWN')
register('JOYBUTTONUP', 'SDL_JOYBUTTONUP')
register('JOYDEVICEADDED', 'SDL_JOYDEVICEADDED')
register('JOYDEVICEREMOVED', 'SDL_JOYDEVICEREMOVED')
register('CONTROLLERAXISMOTION', 'SDL_CONTROLLERAXISMOTION')
register('CONTROLLERBUTTONDOWN', 'SDL_CONTROLLERBUTTONDOWN')
register('CONTROLLERBUTTONUP', 'SDL_CONTROLLERBUTTONUP')
register('CONTROLLERDEVICEADDED', 'SDL_CONTROLLERDEVICEADDED')
register('CONTROLLERDEVICEREMOVED', 'SDL_CONTROLLERDEVICEREMOVED')
register('CONTROLLERDEVICEREMAPPED', 'SDL_CONTROLLERDEVICEREMAPPED')
register('FINGERDOWN', 'SDL_FINGERDOWN')
register('FINGERUP', 'SDL_FINGERUP')
register('FINGERMOTION', 'SDL_FINGERMOTION')
register('DOLLARGESTURE', 'SDL_DOLLARGESTURE')
register('DOLLARRECORD', 'SDL_DOLLARRECORD')
register('MULTIGESTURE', 'SDL_MULTIGESTURE')
register('CLIPBOARDUPDATE', 'SDL_CLIPBOARDUPDATE')
register('DROPFILE', 'SDL_DROPFILE')
register('USEREVENT', 'SDL_USEREVENT')
register('LASTEVENT', 'SDL_LASTEVENT')
register('ADDEVENT', 'SDL_ADDEVENT')
register('PEEKEVENT', 'SDL_PEEKEVENT')
register('GETEVENT', 'SDL_GETEVENT')
register('HINT_DEFAULT', 'SDL_HINT_DEFAULT')
register('HINT_NORMAL', 'SDL_HINT_NORMAL')
register('HINT_OVERRIDE', 'SDL_HINT_OVERRIDE')
register('LOG_CATEGORY_APPLICATION', 'SDL_LOG_CATEGORY_APPLICATION')
register('LOG_CATEGORY_ERROR', 'SDL_LOG_CATEGORY_ERROR')
register('LOG_CATEGORY_ASSERT', 'SDL_LOG_CATEGORY_ASSERT')
register('LOG_CATEGORY_SYSTEM', 'SDL_LOG_CATEGORY_SYSTEM')
register('LOG_CATEGORY_AUDIO', 'SDL_LOG_CATEGORY_AUDIO')
register('LOG_CATEGORY_VIDEO', 'SDL_LOG_CATEGORY_VIDEO')
register('LOG_CATEGORY_RENDER', 'SDL_LOG_CATEGORY_RENDER')
register('LOG_CATEGORY_INPUT', 'SDL_LOG_CATEGORY_INPUT')
register('LOG_CATEGORY_TEST', 'SDL_LOG_CATEGORY_TEST')
register('LOG_CATEGORY_RESERVED1', 'SDL_LOG_CATEGORY_RESERVED1')
register('LOG_CATEGORY_RESERVED2', 'SDL_LOG_CATEGORY_RESERVED2')
register('LOG_CATEGORY_RESERVED3', 'SDL_LOG_CATEGORY_RESERVED3')
register('LOG_CATEGORY_RESERVED4', 'SDL_LOG_CATEGORY_RESERVED4')
register('LOG_CATEGORY_RESERVED5', 'SDL_LOG_CATEGORY_RESERVED5')
register('LOG_CATEGORY_RESERVED6', 'SDL_LOG_CATEGORY_RESERVED6')
register('LOG_CATEGORY_RESERVED7', 'SDL_LOG_CATEGORY_RESERVED7')
register('LOG_CATEGORY_RESERVED8', 'SDL_LOG_CATEGORY_RESERVED8')
register('LOG_CATEGORY_RESERVED9', 'SDL_LOG_CATEGORY_RESERVED9')
register('LOG_CATEGORY_RESERVED10', 'SDL_LOG_CATEGORY_RESERVED10')
register('LOG_CATEGORY_CUSTOM', 'SDL_LOG_CATEGORY_CUSTOM')
register('LOG_PRIORITY_VERBOSE', 'SDL_LOG_PRIORITY_VERBOSE')
register('LOG_PRIORITY_DEBUG', 'SDL_LOG_PRIORITY_DEBUG')
register('LOG_PRIORITY_INFO', 'SDL_LOG_PRIORITY_INFO')
register('LOG_PRIORITY_WARN', 'SDL_LOG_PRIORITY_WARN')
register('LOG_PRIORITY_ERROR', 'SDL_LOG_PRIORITY_ERROR')
register('LOG_PRIORITY_CRITICAL', 'SDL_LOG_PRIORITY_CRITICAL')
register('NUM_LOG_PRIORITIES', 'SDL_NUM_LOG_PRIORITIES')
register('MESSAGEBOX_ERROR', 'SDL_MESSAGEBOX_ERROR')
register('MESSAGEBOX_WARNING', 'SDL_MESSAGEBOX_WARNING')
register('MESSAGEBOX_INFORMATION', 'SDL_MESSAGEBOX_INFORMATION')
register('MESSAGEBOX_BUTTON_RETURNKEY_DEFAULT', 'SDL_MESSAGEBOX_BUTTON_RETURNKEY_DEFAULT')
register('MESSAGEBOX_BUTTON_ESCAPEKEY_DEFAULT', 'SDL_MESSAGEBOX_BUTTON_ESCAPEKEY_DEFAULT')
register('MESSAGEBOX_COLOR_BACKGROUND', 'SDL_MESSAGEBOX_COLOR_BACKGROUND')
register('MESSAGEBOX_COLOR_TEXT', 'SDL_MESSAGEBOX_COLOR_TEXT')
register('MESSAGEBOX_COLOR_BUTTON_BORDER', 'SDL_MESSAGEBOX_COLOR_BUTTON_BORDER')
register('MESSAGEBOX_COLOR_BUTTON_BACKGROUND', 'SDL_MESSAGEBOX_COLOR_BUTTON_BACKGROUND')
register('MESSAGEBOX_COLOR_BUTTON_SELECTED', 'SDL_MESSAGEBOX_COLOR_BUTTON_SELECTED')
register('MESSAGEBOX_COLOR_MAX', 'SDL_MESSAGEBOX_COLOR_MAX')
register('MESSAGEBOX_COLOR_MAX', 'SDL_MESSAGEBOX_COLOR_MAX')
register('POWERSTATE_UNKNOWN', 'SDL_POWERSTATE_UNKNOWN')
register('POWERSTATE_ON_BATTERY', 'SDL_POWERSTATE_ON_BATTERY')
register('POWERSTATE_NO_BATTERY', 'SDL_POWERSTATE_NO_BATTERY')
register('POWERSTATE_CHARGING', 'SDL_POWERSTATE_CHARGING')
register('POWERSTATE_CHARGED', 'SDL_POWERSTATE_CHARGED')
register('RENDERER_SOFTWARE', 'SDL_RENDERER_SOFTWARE')
register('RENDERER_ACCELERATED', 'SDL_RENDERER_ACCELERATED')
register('RENDERER_PRESENTVSYNC', 'SDL_RENDERER_PRESENTVSYNC')
register('RENDERER_TARGETTEXTURE', 'SDL_RENDERER_TARGETTEXTURE')
register('TEXTUREACCESS_STATIC', 'SDL_TEXTUREACCESS_STATIC')
register('TEXTUREACCESS_STREAMING', 'SDL_TEXTUREACCESS_STREAMING')
register('TEXTUREACCESS_TARGET', 'SDL_TEXTUREACCESS_TARGET')
register('TEXTUREMODULATE_NONE', 'SDL_TEXTUREMODULATE_NONE')
register('TEXTUREMODULATE_COLOR', 'SDL_TEXTUREMODULATE_COLOR')
register('TEXTUREMODULATE_ALPHA', 'SDL_TEXTUREMODULATE_ALPHA')
register('FLIP_NONE', 'SDL_FLIP_NONE')
register('FLIP_HORIZONTAL', 'SDL_FLIP_HORIZONTAL')
register('FLIP_VERTICAL', 'SDL_FLIP_VERTICAL')
register('INIT_TIMER', 'SDL_INIT_TIMER')
register('INIT_AUDIO', 'SDL_INIT_AUDIO')
register('INIT_VIDEO', 'SDL_INIT_VIDEO')
register('INIT_JOYSTICK', 'SDL_INIT_JOYSTICK')
register('INIT_HAPTIC', 'SDL_INIT_HAPTIC')
register('INIT_GAMECONTROLLER', 'SDL_INIT_GAMECONTROLLER')
register('INIT_EVENTS', 'SDL_INIT_EVENTS')
register('INIT_NOPARACHUTE', 'SDL_INIT_NOPARACHUTE')
register('INIT_EVERYTHING', 'SDL_INIT_EVERYTHING')
register('INIT_TIMER', 'SDL_INIT_TIMER')
register('INIT_AUDIO', 'SDL_INIT_AUDIO')
register('INIT_VIDEO', 'SDL_INIT_VIDEO')
register('INIT_EVENTS', 'SDL_INIT_EVENTS')
register('INIT_JOYSTICK', 'SDL_INIT_JOYSTICK')
register('INIT_HAPTIC', 'SDL_INIT_HAPTIC')
register('INIT_GAMECONTROLLER', 'SDL_INIT_GAMECONTROLLER')
register('AUDIO_MASK_BITSIZE', 'SDL_AUDIO_MASK_BITSIZE')
register('AUDIO_MASK_DATATYPE', 'SDL_AUDIO_MASK_DATATYPE')
register('AUDIO_MASK_ENDIAN', 'SDL_AUDIO_MASK_ENDIAN')
register('AUDIO_MASK_SIGNED', 'SDL_AUDIO_MASK_SIGNED')
register('AUDIO_U8', 'SDL_AUDIO_U8')
register('AUDIO_S8', 'SDL_AUDIO_S8')
register('AUDIO_U16LSB', 'SDL_AUDIO_U16LSB')
register('AUDIO_S16LSB', 'SDL_AUDIO_S16LSB')
register('AUDIO_U16MSB', 'SDL_AUDIO_U16MSB')
register('AUDIO_S16MSB', 'SDL_AUDIO_S16MSB')
register('AUDIO_U16', 'SDL_AUDIO_U16')
register('AUDIO_U16LSB', 'SDL_AUDIO_U16LSB')
register('AUDIO_S16', 'SDL_AUDIO_S16')
register('AUDIO_S16LSB', 'SDL_AUDIO_S16LSB')
register('AUDIO_S32LSB', 'SDL_AUDIO_S32LSB')
register('AUDIO_S32MSB', 'SDL_AUDIO_S32MSB')
register('AUDIO_S32', 'SDL_AUDIO_S32')
register('AUDIO_S32LSB', 'SDL_AUDIO_S32LSB')
register('AUDIO_F32LSB', 'SDL_AUDIO_F32LSB')
register('AUDIO_F32MSB', 'SDL_AUDIO_F32MSB')
register('AUDIO_F32', 'SDL_AUDIO_F32')
register('AUDIO_F32LSB', 'SDL_AUDIO_F32LSB')
register('AUDIO_ALLOW_FREQUENCY_CHANGE', 'SDL_AUDIO_ALLOW_FREQUENCY_CHANGE')
register('AUDIO_ALLOW_FORMAT_CHANGE', 'SDL_AUDIO_ALLOW_FORMAT_CHANGE')
register('AUDIO_ALLOW_CHANNELS_CHANGE', 'SDL_AUDIO_ALLOW_CHANNELS_CHANGE')
register('AUDIO_ALLOW_ANY_CHANGE', 'SDL_AUDIO_ALLOW_ANY_CHANGE')
register('AUDIO_ALLOW_FREQUENCY_CHANGE', 'SDL_AUDIO_ALLOW_FREQUENCY_CHANGE')
register('AUDIO_ALLOW_FORMAT_CHANGE', 'SDL_AUDIO_ALLOW_FORMAT_CHANGE')
register('AUDIO_ALLOW_CHANNELS_CHANGE', 'SDL_AUDIO_ALLOW_CHANNELS_CHANGE')
register('MIX_MAXVOLUME', 'SDL_MIX_MAXVOLUME')
register('RELEASED', 'SDL_RELEASED')
register('PRESSED', 'SDL_PRESSED')
register('QUERY', 'SDL_QUERY')
register('IGNORE', 'SDL_IGNORE')
register('DISABLE', 'SDL_DISABLE')
register('ENABLE', 'SDL_ENABLE')
register('HAPTIC_CONSTANT', 'SDL_HAPTIC_CONSTANT')
register('HAPTIC_SINE', 'SDL_HAPTIC_SINE')
register('HAPTIC_LEFTRIGHT', 'SDL_HAPTIC_LEFTRIGHT')
register('HAPTIC_TRIANGLE', 'SDL_HAPTIC_TRIANGLE')
register('HAPTIC_SAWTOOTHUP', 'SDL_HAPTIC_SAWTOOTHUP')
register('HAPTIC_SAWTOOTHDOWN', 'SDL_HAPTIC_SAWTOOTHDOWN')
register('HAPTIC_RAMP', 'SDL_HAPTIC_RAMP')
register('HAPTIC_SPRING', 'SDL_HAPTIC_SPRING')
register('HAPTIC_DAMPER', 'SDL_HAPTIC_DAMPER')
register('HAPTIC_INERTIA', 'SDL_HAPTIC_INERTIA')
register('HAPTIC_FRICTION', 'SDL_HAPTIC_FRICTION')
register('HAPTIC_CUSTOM', 'SDL_HAPTIC_CUSTOM')
register('HAPTIC_GAIN', 'SDL_HAPTIC_GAIN')
register('HAPTIC_AUTOCENTER', 'SDL_HAPTIC_AUTOCENTER')
register('HAPTIC_STATUS', 'SDL_HAPTIC_STATUS')
register('HAPTIC_PAUSE', 'SDL_HAPTIC_PAUSE')
register('HAPTIC_POLAR', 'SDL_HAPTIC_POLAR')
register('HAPTIC_CARTESIAN', 'SDL_HAPTIC_CARTESIAN')
register('HAPTIC_SPHERICAL', 'SDL_HAPTIC_SPHERICAL')
register('HAPTIC_INFINITY', 'SDL_HAPTIC_INFINITY')
register('HAT_CENTERED', 'SDL_HAT_CENTERED')
register('HAT_UP', 'SDL_HAT_UP')
register('HAT_RIGHT', 'SDL_HAT_RIGHT')
register('HAT_DOWN', 'SDL_HAT_DOWN')
register('HAT_LEFT', 'SDL_HAT_LEFT')
register('HAT_RIGHTUP', 'SDL_HAT_RIGHTUP')
register('HAT_RIGHT', 'SDL_HAT_RIGHT')
register('HAT_UP', 'SDL_HAT_UP')
register('HAT_RIGHTDOWN', 'SDL_HAT_RIGHTDOWN')
register('HAT_RIGHT', 'SDL_HAT_RIGHT')
register('HAT_DOWN', 'SDL_HAT_DOWN')
register('HAT_LEFTUP', 'SDL_HAT_LEFTUP')
register('HAT_LEFT', 'SDL_HAT_LEFT')
register('HAT_UP', 'SDL_HAT_UP')
register('HAT_LEFTDOWN', 'SDL_HAT_LEFTDOWN')
register('HAT_LEFT', 'SDL_HAT_LEFT')
register('HAT_DOWN', 'SDL_HAT_DOWN')
register('SCANCODE_MASK', 'SDL_SCANCODE_MASK')
register('KMOD_CTRL', 'SDL_KMOD_CTRL')
register('KMOD_LCTRL', 'SDL_KMOD_LCTRL')
register('KMOD_RCTRL', 'SDL_KMOD_RCTRL')
register('KMOD_SHIFT', 'SDL_KMOD_SHIFT')
register('KMOD_LSHIFT', 'SDL_KMOD_LSHIFT')
register('KMOD_RSHIFT', 'SDL_KMOD_RSHIFT')
register('KMOD_ALT', 'SDL_KMOD_ALT')
register('KMOD_LALT', 'SDL_KMOD_LALT')
register('KMOD_RALT', 'SDL_KMOD_RALT')
register('KMOD_GUI', 'SDL_KMOD_GUI')
register('KMOD_LGUI', 'SDL_KMOD_LGUI')
register('KMOD_RGUI', 'SDL_KMOD_RGUI')
register('BUTTON_LEFT', 'SDL_BUTTON_LEFT')
register('BUTTON_MIDDLE', 'SDL_BUTTON_MIDDLE')
register('BUTTON_RIGHT', 'SDL_BUTTON_RIGHT')
register('BUTTON_X1', 'SDL_BUTTON_X1')
register('BUTTON_X2', 'SDL_BUTTON_X2')
register('BUTTON_LMASK', 'SDL_BUTTON_LMASK')
register('BUTTON_LEFT-1', 'SDL_BUTTON_LEFT-1')
register('BUTTON_MMASK', 'SDL_BUTTON_MMASK')
register('BUTTON_MIDDLE-1', 'SDL_BUTTON_MIDDLE-1')
register('BUTTON_RMASK', 'SDL_BUTTON_RMASK')
register('BUTTON_RIGHT-1', 'SDL_BUTTON_RIGHT-1')
register('BUTTON_X1MASK', 'SDL_BUTTON_X1MASK')
register('BUTTON_X1-1', 'SDL_BUTTON_X1-1')
register('BUTTON_X2MASK', 'SDL_BUTTON_X2MASK')
register('BUTTON_X2-1', 'SDL_BUTTON_X2-1')
register('MUTEX_TIMEDOUT', 'SDL_MUTEX_TIMEDOUT')
register('MUTEX_MAXWAIT', 'SDL_MUTEX_MAXWAIT')
register('ALPHA_OPAQUE', 'SDL_ALPHA_OPAQUE')
register('ALPHA_TRANSPARENT', 'SDL_ALPHA_TRANSPARENT')
register('RWOPS_UNKNOWN', 'SDL_RWOPS_UNKNOWN')
register('RWOPS_WINFILE', 'SDL_RWOPS_WINFILE')
register('RWOPS_STDFILE', 'SDL_RWOPS_STDFILE')
register('RWOPS_JNIFILE', 'SDL_RWOPS_JNIFILE')
register('RWOPS_MEMORY', 'SDL_RWOPS_MEMORY')
register('RWOPS_MEMORY_RO', 'SDL_RWOPS_MEMORY_RO')
register('NONSHAPEABLE_WINDOW', 'SDL_NONSHAPEABLE_WINDOW')
register('INVALID_SHAPE_ARGUMENT', 'SDL_INVALID_SHAPE_ARGUMENT')
register('WINDOW_LACKS_SHAPE', 'SDL_WINDOW_LACKS_SHAPE')
register('SWSURFACE', 'SDL_SWSURFACE')
register('PREALLOC', 'SDL_PREALLOC')
register('RLEACCEL', 'SDL_RLEACCEL')
register('DONTFREE', 'SDL_DONTFREE')
register('WINDOWPOS_CENTERED_MASK', 'SDL_WINDOWPOS_CENTERED_MASK')
register('WINDOWPOS_CENTERED', 'SDL_WINDOWPOS_CENTERED')
register('WINDOWPOS_UNDEFINED_MASK', 'SDL_WINDOWPOS_UNDEFINED_MASK')
register('WINDOWPOS_UNDEFINED', 'SDL_WINDOWPOS_UNDEFINED')

registerdefines(sdl)

return sdl
]]):gsub('\\([%]%[])','%1')
sources["hate.cpml.modules.intersect"]=([[-- <pack hate.cpml.modules.intersect> --
local current_folder = (...):gsub('%.\[^%.\]+$', '') .. "."
local vec3 = require(current_folder .. "vec3")
local constants = require(current_folder .. "constants")

local intersect = {}

-- http://www.lighthouse3d.com/tutorials/maths/ray-triangle-intersection/
function intersect.ray_triangle(ray, triangle)
	assert(ray.point ~= nil)
	assert(ray.direction ~= nil)
	assert(#triangle == 3)

	local p, d = ray.point, ray.direction

	local h, s, q = vec3(), vec3(), vec3()
	local a, f, u, v

	local e1 = triangle\[2\] - triangle\[1\]
	local e2 = triangle\[3\] - triangle\[1\]

	h = d:clone():cross(e2)

	a = (e1:dot(h))

	if a > -0.00001 and a < 0.00001 then
		return false
	end

	f = 1/a
	s = p - triangle\[1\]
	u = f * (s:dot(h))

	if u < 0 or u > 1 then
		return false
	end

	q = s:clone():cross(e1)
	v = f * (d:dot(q))

	if v < 0 or u + v > 1 then
		return false
	end

	-- at this stage we can compute t to find out where
	-- the intersection point is on the line
	t = f * (e2:dot(q))

	if t > constants.FLT_EPSILON then
		return p + t * d -- we've got a hit!
	else
		return false -- the line intersects, but it's behind the point
	end
end

-- Algorithm is ported from the C algorithm of 
-- Paul Bourke at http://local.wasp.uwa.edu.au/~pbourke/geometry/lineline3d/
-- Archive.org am hero \o/
function intersect.line_line(p1, p2, p3, p4)
	local epsilon = constants.FLT_EPSILON
	local resultSegmentPoint1 = vec3(0,0,0)
	local resultSegmentPoint2 = vec3(0,0,0)

	local p13 = p1 - p3
	local p43 = p4 - p3
	local p21 = p2 - p1

	if p43:len2() < epsilon then return false end
	if p21:len2() < epsilon then return false end

	local d1343 = p13.x * p43.x + p13.y * p43.y + p13.z * p43.z
	local d4321 = p43.x * p21.x + p43.y * p21.y + p43.z * p21.z
	local d1321 = p13.x * p21.x + p13.y * p21.y + p13.z * p21.z
	local d4343 = p43.x * p43.x + p43.y * p43.y + p43.z * p43.z
	local d2121 = p21.x * p21.x + p21.y * p21.y + p21.z * p21.z

	local denom = d2121 * d4343 - d4321 * d4321
	if math.abs(denom) < epsilon then return false end
	local numer = d1343 * d4321 - d1321 * d4343

	local mua = numer / denom
	local mub = (d1343 + d4321 * (mua)) / d4343

	resultSegmentPoint1.x = p1.x + mua * p21.x
	resultSegmentPoint1.y = p1.y + mua * p21.y
	resultSegmentPoint1.z = p1.z + mua * p21.z
	resultSegmentPoint2.x = p3.x + mub * p43.x
	resultSegmentPoint2.y = p3.y + mub * p43.y
	resultSegmentPoint2.z = p3.z + mub * p43.z

	return true, resultSegmentPoint1, resultSegmentPoint2
end

function intersect.circle_circle(c1, c2)
	assert(type(c1.point)	== "table", "c1 point must be a table")
	assert(type(c1.radius)	== "number", "c1 radius must be a number")
	assert(type(c2.point)	== "table", "c2 point must be a table")
	assert(type(c2.radius)	== "number", "c2 radius must be a number")
	return c1.point:dist(c2.point) <= c1.radius + c2.radius
end

return intersect
]]):gsub('\\([%]%[])','%1')
sources["hate.cpml.modules.vec3"]=([[-- <pack hate.cpml.modules.vec3> --
--\[\[
Copyright (c) 2010-2013 Matthias Richter

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

Except as contained in this notice, the name(s) of the above copyright holders
shall not be used in advertising or otherwise to promote the sale, use or
other dealings in this Software without prior written authorization.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.
\]\]--

-- Modified to include 3D capabilities by Bill Shillito, April 2014
-- Various bug fixes by Colby Klein, October 2014

local assert = assert
local sqrt, cos, sin, atan2, acos = math.sqrt, math.cos, math.sin, math.atan2, math.acos

local vector = {}
vector.__index = vector

local function new(x,y,z)
	if type(x) == "table" then
		return setmetatable({x = x.x or x\[1\] or 0, y = x.y or x\[2\] or 0, z = x.z or x\[3\] or 0}, vector)
	end

	return setmetatable({x = x or 0, y = y or 0, z = z or 0}, vector)
end
local zero = new(0,0,0)

local function isvector(v)
	return type(v) == 'table' and type(v.x) == 'number' and type(v.y) == 'number' and type(v.z) == 'number'
end

function vector:clone()
	return new(self.x, self.y, self.z)
end

function vector:unpack()
	return self.x, self.y, self.z
end

function vector:__tostring()
	return "("..tonumber(self.x)..","..tonumber(self.y)..","..tonumber(self.z)..")"
end

function vector.__unm(a)
	return new(-a.x, -a.y, -a.z)
end

function vector.__add(a,b)
	assert(isvector(a) and isvector(b), "Add: wrong argument types (<vector> expected)")
	return new(a.x+b.x, a.y+b.y, a.z+b.z)
end

function vector.__sub(a,b)
	assert(isvector(a) and isvector(b), "Sub: wrong argument types (<vector> expected)")
	return new(a.x-b.x, a.y-b.y, a.z-b.z)
end

function vector.__mul(a,b)
	if type(a) == "number" then
		return new(a*b.x, a*b.y, a*b.z)
	elseif type(b) == "number" then
		return new(b*a.x, b*a.y, b*a.z)
	else
		assert(isvector(a) and isvector(b), "Mul: wrong argument types (<vector> or <number> expected)")
		return new(a.x*b.x, a.y*b.y, a.z*b.z)
	end
end

function vector.__div(a,b)
	assert(isvector(a) and type(b) == "number", "wrong argument types (expected <vector> / <number>)")
	return new(a.x / b, a.y / b, a.z / b)
end

function vector.__eq(a,b)
	return a.x == b.x and a.y == b.y and a.z == b.z
end

function vector.__lt(a,b)
	-- This is a lexicographical order.
	return a.x < b.x or (a.x == b.x and a.y < b.y) or (a.x == b.x and a.y == b.y and a.z < b.z)
end

function vector.__le(a,b)
	-- This is a lexicographical order.
	return a.x <= b.x and a.y <= b.y and a.z <= b.z
end

function vector.dot(a,b)
	assert(isvector(a) and isvector(b), "dot: wrong argument types (<vector> expected)")
	return a.x*b.x + a.y*b.y + a.z*b.z
end

function vector:len2()
	return self.x * self.x + self.y * self.y + self.z * self.z
end

function vector:len()
	return sqrt(self.x * self.x + self.y * self.y + self.z * self.z)
end

function vector.dist(a, b)
	assert(isvector(a) and isvector(b), "dist: wrong argument types (<vector> expected)")
	local dx = a.x - b.x
	local dy = a.y - b.y
	local dz = a.z - b.z
	return sqrt(dx * dx + dy * dy + dz * dz)
end

function vector.dist2(a, b)
	assert(isvector(a) and isvector(b), "dist: wrong argument types (<vector> expected)")
	local dx = a.x - b.x
	local dy = a.y - b.y
	local dz = a.z - b.z
	return (dx * dx + dy * dy + dz * dz)
end

function vector:normalize_inplace()
	local l = self:len()
	if l > 0 then
		self.x, self.y, self.z = self.x / l, self.y / l, self.z / l
	end
	return self
end

function vector:normalize()
	return self:clone():normalize_inplace()
end

function vector:rotate(phi, axis)
	if axis == nil then return self end

	local u = axis:normalize() or Vector(0,0,1) -- default is to rotate in the xy plane
	local c, s = cos(phi), sin(phi)

	-- Calculate generalized rotation matrix
	local m1 = new((c + u.x * u.x * (1-c)),       (u.x * u.y * (1-c) - u.z * s), (u.x * u.z * (1-c) + u.y * s))
	local m2 = new((u.y * u.x * (1-c) + u.z * s), (c + u.y * u.y * (1-c)),       (u.y * u.z * (1-c) - u.x * s))
	local m3 = new((u.z * u.x * (1-c) - u.y * s), (u.z * u.y * (1-c) + u.x * s), (c + u.z * u.z * (1-c))      )

	-- Return rotated vector
	return new( m1:dot(self), m2:dot(self), m3:dot(self) )
end

function vector:rotate_inplace(phi, axis)
	self = self:rotated(phi, axis)
end

function vector:perpendicular()
	return new(-self.y, self.x, 0)
end

function vector:project_on(v)
	assert(isvector(v), "invalid argument: cannot project vector on " .. type(v))
	-- (self * v) * v / v:len2()
	local s = (self.x * v.x + self.y * v.y + self.z * v.z) / (v.x * v.x + v.y * v.y + v.z * v.z)
	return new(s * v.x, s * v.y, s * v.z)
end

function vector:project_from(v)
	assert(isvector(v), "invalid argument: cannot project vector on " .. type(v))
	-- Does the reverse of projectOn.
	local s = (v.x * v.x + v.y * v.y + v.z * v.z) / (self.x * v.x + self.y * v.y + self.z * v.z)
	return new(s * v.x, s * v.y, s * v.z)
end

function vector:mirror_on(v)
	assert(isvector(v), "invalid argument: cannot mirror vector on " .. type(v))
	-- 2 * self:projectOn(v) - self
	local s = 2 * (self.x * v.x + self.y * v.y + self.z * v.z) / (v.x * v.x + v.y * v.y + v.z * v.z)
	return new(s * v.x - self.x, s * v.y - self.y, s * v.z - self.z)
end

function vector:cross(v)
	-- Cross product.
	assert(isvector(v), "cross: wrong argument types (<vector> expected)")
	return new(self.y*v.z - self.z*v.y, self.z*v.x - self.x*v.z, self.x*v.y - self.y*v.x)
	--return self.x * v.y - self.y * v.x
end

-- ref.: http://blog.signalsondisplay.com/?p=336
function vector:trim_inplace(maxLen)
	local s = maxLen * maxLen / self:len2()
	s = (s > 1 and 1) or math.sqrt(s)
	self.x, self.y, self.z = self.x * s, self.y * s, self.z * s
	return self
end

function vector:angle_to(other)
	-- Only makes sense in 2D.
	if other then
		return atan2(self.y, self.x) - atan2(other.y, other.x)
	end
	return atan2(self.y, self.x)
end

function vector:angle_between(other)
	if other then
		return acos(self*other / (self:len() * other:len()))
	end
	return 0
end

function vector:trim(maxLen)
	return self:clone():trim_inplace(maxLen)
end

function vector:orientation_to_direction(orientation)
	orientation = orientation or new(0, 1, 0)
	return orientation
		:rotated(self.z, new(0, 0, 1))
		:rotated(self.y, new(0, 1, 0))
		:rotated(self.x, new(1, 0, 0))
end

-- http://keithmaggio.wordpress.com/2011/02/15/math-magician-lerp-slerp-and-nlerp/
function vector.lerp(a, b, s)
	return a + s * (b - a)
end

-- the module
return setmetatable({new = new, isvector = isvector, zero = zero},
{__call = function(_, ...) return new(...) end})
]]):gsub('\\([%]%[])','%1')
sources["hate.cpml.modules.constants"]=([[-- <pack hate.cpml.modules.constants> --
local constants = {}

-- same as C's FLT_EPSILON
constants.FLT_EPSILON = 1.19209290e-07

-- used for quaternion.slerp
constants.DOT_THRESHOLD = 0.9995

return constants
]]):gsub('\\([%]%[])','%1')
sources["hate.cpml.modules.simplex"]=([[-- <pack hate.cpml.modules.simplex> --
--
-- Based on code in "Simplex noise demystified", by Stefan Gustavson
-- www.itn.liu.se/~stegu/simplexnoise/simplexnoise.pdf
--
-- Thanks to Mike Pall for some cleanup and improvements (and for LuaJIT!)
--
-- Permission is hereby granted, free of charge, to any person obtaining
-- a copy of this software and associated documentation files (the
-- "Software"), to deal in the Software without restriction, including
-- without limitation the rights to use, copy, modify, merge, publish,
-- distribute, sublicense, and/or sell copies of the Software, and to
-- permit persons to whom the Software is furnished to do so, subject to
-- the following conditions:
--
-- The above copyright notice and this permission notice shall be
-- included in all copies or substantial portions of the Software.
--
-- THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
-- EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
-- MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.
-- IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY
-- CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT,
-- TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE
-- SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
--
-- \[ MIT license: http://www.opensource.org/licenses/mit-license.php \]
--

-- Bail out with dummy module if FFI is missing.
local has_ffi, ffi = pcall(require, "ffi")

if not has_ffi then
	return {
		Simplex2D = function() return 0 end,
		Simplex3D = function() return 0 end,
		Simplex4D = function() return 0 end
	}
end

-- Modules --
local bit = require("bit")
local math = require("math")

-- Imports --
local band = bit.band
local bor = bit.bor
local bxor = bit.bxor
local floor = math.floor
local lshift = bit.lshift
local max = math.max
local rshift = bit.rshift

-- Module table --
local M = {}

-- Permutation of 0-255, replicated to allow easy indexing with sums of two bytes --
local Perms = ffi.new("uint8_t\[512\]", {
	151, 160, 137, 91, 90, 15, 131, 13, 201, 95, 96, 53, 194, 233, 7, 225,
	140, 36, 103, 30, 69, 142, 8, 99, 37, 240, 21, 10, 23, 190, 6, 148,
	247, 120, 234, 75, 0, 26, 197, 62, 94, 252, 219, 203, 117, 35, 11, 32,
	57, 177, 33, 88, 237, 149, 56, 87, 174, 20, 125, 136, 171, 168, 68,	175,
	74, 165, 71, 134, 139, 48, 27, 166, 77, 146, 158, 231, 83, 111,	229, 122,
	60, 211, 133, 230, 220, 105, 92, 41, 55, 46, 245, 40, 244, 102, 143, 54,
	65, 25, 63, 161, 1, 216, 80, 73, 209, 76, 132, 187, 208, 89, 18, 169,
	200, 196, 135, 130, 116, 188, 159, 86, 164, 100, 109, 198, 173, 186, 3, 64,
	52, 217, 226, 250, 124, 123, 5, 202, 38, 147, 118, 126, 255, 82, 85, 212,
	207, 206, 59, 227, 47, 16, 58, 17, 182, 189, 28, 42, 223, 183, 170, 213,
	119, 248, 152, 2, 44, 154, 163, 70, 221, 153, 101, 155, 167, 43, 172, 9,
	129, 22, 39, 253, 19, 98, 108, 110, 79, 113, 224, 232, 178, 185, 112, 104,
	218, 246, 97, 228, 251, 34, 242, 193, 238, 210, 144, 12, 191, 179, 162, 241,
	81,	51, 145, 235, 249, 14, 239,	107, 49, 192, 214, 31, 181, 199, 106, 157,
	184, 84, 204, 176, 115, 121, 50, 45, 127, 4, 150, 254, 138, 236, 205, 93,
	222, 114, 67, 29, 24, 72, 243, 141, 128, 195, 78, 66, 215, 61, 156, 180
})

-- The above, mod 12 for each element --
local Perms12 = ffi.new("uint8_t\[512\]")

for i = 0, 255 do
	local x = Perms\[i\] % 12

	Perms\[i + 256\], Perms12\[i\], Perms12\[i + 256\] = Perms\[i\], x, x
end

-- Gradients for 2D, 3D case --
local Grads3 = ffi.new("const double\[12\]\[3\]",
	{ 1, 1, 0 }, { -1, 1, 0 }, { 1, -1, 0 }, { -1, -1, 0 },
	{ 1, 0, 1 }, { -1, 0, 1 }, { 1, 0, -1 }, { -1, 0, -1 },
	{ 0, 1, 1 }, { 0, -1, 1 }, { 0, 1, -1 }, { 0, -1, -1 }
)

do
	-- 2D weight contribution
	local function GetN (bx, by, x, y)
		local t = .5 - x * x - y * y
		local index = Perms12\[bx + Perms\[by\]\]

		return max(0, (t * t) * (t * t)) * (Grads3\[index\]\[0\] * x + Grads3\[index\]\[1\] * y)
	end

	---
	-- @param x
	-- @param y
	-- @return Noise value in the range \[-1, +1\]
	function M.Simplex2D (x, y)
		--\[\[
			2D skew factors:
			F = (math.sqrt(3) - 1) / 2
			G = (3 - math.sqrt(3)) / 6
			G2 = 2 * G - 1
		\]\]

		-- Skew the input space to determine which simplex cell we are in.
		local s = (x + y) * 0.366025403 -- F
		local ix, iy = floor(x + s), floor(y + s)

		-- Unskew the cell origin back to (x, y) space.
		local t = (ix + iy) * 0.211324865 -- G
		local x0 = x + t - ix
		local y0 = y + t - iy

		-- Calculate the contribution from the two fixed corners.
		-- A step of (1,0) in (i,j) means a step of (1-G,-G) in (x,y), and
		-- A step of (0,1) in (i,j) means a step of (-G,1-G) in (x,y).
		ix, iy = band(ix, 255), band(iy, 255)

		local n0 = GetN(ix, iy, x0, y0)
		local n2 = GetN(ix + 1, iy + 1, x0 - 0.577350270, y0 - 0.577350270) -- G2

		--\[\[
			Determine other corner based on simplex (equilateral triangle) we are in:
			if x0 > y0 then
				ix, x1 = ix + 1, x1 - 1
			else
				iy, y1 = iy + 1, y1 - 1
			end
		\]\]
		local xi = rshift(floor(y0 - x0), 31) -- y0 < x0
		local n1 = GetN(ix + xi, iy + (1 - xi), x0 + 0.211324865 - xi, y0 - 0.788675135 + xi) -- x0 + G - xi, y0 + G - (1 - xi)

		-- Add contributions from each corner to get the final noise value.
		-- The result is scaled to return values in the interval \[-1,1\].
		return 70.1480580019 * (n0 + n1 + n2)
	end
end

do
	-- 3D weight contribution
	local function GetN (ix, iy, iz, x, y, z)
		local t = .6 - x * x - y * y - z * z
		local index = Perms12\[ix + Perms\[iy + Perms\[iz\]\]\]

		return max(0, (t * t) * (t * t)) * (Grads3\[index\]\[0\] * x + Grads3\[index\]\[1\] * y + Grads3\[index\]\[2\] * z)
	end

	---
	-- @param x
	-- @param y
	-- @param z
	-- @return Noise value in the range \[-1, +1\]
	function M.Simplex3D (x, y, z)
		--\[\[
			3D skew factors:
			F = 1 / 3
			G = 1 / 6
			G2 = 2 * G
			G3 = 3 * G - 1
		\]\]

		-- Skew the input space to determine which simplex cell we are in.
		local s = (x + y + z) * 0.333333333 -- F
		local ix, iy, iz = floor(x + s), floor(y + s), floor(z + s)

		-- Unskew the cell origin back to (x, y, z) space.
		local t = (ix + iy + iz) * 0.166666667 -- G
		local x0 = x + t - ix
		local y0 = y + t - iy
		local z0 = z + t - iz

		-- Calculate the contribution from the two fixed corners.
		-- A step of (1,0,0) in (i,j,k) means a step of (1-G,-G,-G) in (x,y,z);
		-- a step of (0,1,0) in (i,j,k) means a step of (-G,1-G,-G) in (x,y,z);
		-- a step of (0,0,1) in (i,j,k) means a step of (-G,-G,1-G) in (x,y,z).
		ix, iy, iz = band(ix, 255), band(iy, 255), band(iz, 255)

		local n0 = GetN(ix, iy, iz, x0, y0, z0)
		local n3 = GetN(ix + 1, iy + 1, iz + 1, x0 - 0.5, y0 - 0.5, z0 - 0.5) -- G3

		--\[\[
			Determine other corners based on simplex (skewed tetrahedron) we are in:

			if x0 >= y0 then -- ~A
				if y0 >= z0 then -- ~A and ~B
					i1, j1, k1, i2, j2, k2 = 1, 0, 0, 1, 1, 0
				elseif x0 >= z0 then -- ~A and B and ~C
					i1, j1, k1, i2, j2, k2 = 1, 0, 0, 1, 0, 1
				else -- ~A and B and C
					i1, j1, k1, i2, j2, k2 = 0, 0, 1, 1, 0, 1
				end
			else -- A
				if y0 < z0 then -- A and B
					i1, j1, k1, i2, j2, k2 = 0, 0, 1, 0, 1, 1
				elseif x0 < z0 then -- A and ~B and C
					i1, j1, k1, i2, j2, k2 = 0, 1, 0, 0, 1, 1
				else -- A and ~B and ~C
					i1, j1, k1, i2, j2, k2 = 0, 1, 0, 1, 1, 0
				end
			end
		\]\]

		local xLy = rshift(floor(x0 - y0), 31) -- x0 < y0
		local yLz = rshift(floor(y0 - z0), 31) -- y0 < z0
		local xLz = rshift(floor(x0 - z0), 31) -- x0 < z0

		local i1 = band(1 - xLy, bor(1 - yLz, 1 - xLz)) -- x0 >= y0 and (y0 >= z0 or x0 >= z0)
		local j1 = band(xLy, 1 - yLz) -- x0 < y0 and y0 >= z0
		local k1 = band(yLz, bor(xLy, xLz)) -- y0 < z0 and (x0 < y0 or x0 < z0)

		local i2 = bor(1 - xLy, band(1 - yLz, 1 - xLz)) -- x0 >= y0 or (y0 >= z0 and x0 >= z0)
		local j2 = bor(xLy, 1 - yLz) -- x0 < y0 or y0 >= z0
		local k2 = bor(band(1 - xLy, yLz), band(xLy, bor(yLz, xLz))) -- (x0 >= y0 and y0 < z0) or (x0 < y0 and (y0 < z0 or x0 < z0))

		local n1 = GetN(ix + i1, iy + j1, iz + k1, x0 + 0.166666667 - i1, y0 + 0.166666667 - j1, z0 + 0.166666667 - k1) -- G
		local n2 = GetN(ix + i2, iy + j2, iz + k2, x0 + 0.333333333 - i2, y0 + 0.333333333 - j2, z0 + 0.333333333 - k2) -- G2

		-- Add contributions from each corner to get the final noise value.
		-- The result is scaled to stay just inside \[-1,1\]
		return 28.452842 * (n0 + n1 + n2 + n3)
	end
end

do
	-- Gradients for 4D case --
	local Grads4 = ffi.new("const double\[32\]\[4\]",
		{ 0, 1, 1, 1 }, { 0, 1, 1, -1 }, { 0, 1, -1, 1 }, { 0, 1, -1, -1 },
		{ 0, -1, 1, 1 }, { 0, -1, 1, -1 }, { 0, -1, -1, 1 }, { 0, -1, -1, -1 },
		{ 1, 0, 1, 1 }, { 1, 0, 1, -1 }, { 1, 0, -1, 1 }, { 1, 0, -1, -1 },
		{ -1, 0, 1, 1 }, { -1, 0, 1, -1 }, { -1, 0, -1, 1 }, { -1, 0, -1, -1 },
		{ 1, 1, 0, 1 }, { 1, 1, 0, -1 }, { 1, -1, 0, 1 }, { 1, -1, 0, -1 },
		{ -1, 1, 0, 1 }, { -1, 1, 0, -1 }, { -1, -1, 0, 1 }, { -1, -1, 0, -1 },
		{ 1, 1, 1, 0 }, { 1, 1, -1, 0 }, { 1, -1, 1, 0 }, { 1, -1, -1, 0 },
		{ -1, 1, 1, 0 }, { -1, 1, -1, 0 }, { -1, -1, 1, 0 }, { -1, -1, -1, 0 }
	)

	-- 4D weight contribution
	local function GetN (ix, iy, iz, iw, x, y, z, w)
		local t = .6 - x * x - y * y - z * z - w * w
		local index = band(Perms\[ix + Perms\[iy + Perms\[iz + Perms\[iw\]\]\]\], 0x1F)

		return max(0, (t * t) * (t * t)) * (Grads4\[index\]\[0\] * x + Grads4\[index\]\[1\] * y + Grads4\[index\]\[2\] * z + Grads4\[index\]\[3\] * w)
	end

	-- A lookup table to traverse the simplex around a given point in 4D.
	-- Details can be found where this table is used, in the 4D noise method.
	local Simplex = ffi.new("uint8_t\[64\]\[4\]",
		{ 0, 1, 2, 3 }, { 0, 1, 3, 2 }, {}, { 0, 2, 3, 1 }, {}, {}, {}, { 1, 2, 3 },
		{ 0, 2, 1, 3 }, {}, { 0, 3, 1, 2 }, { 0, 3, 2, 1 }, {}, {}, {}, { 1, 3, 2 },
		{}, {}, {}, {}, {}, {}, {}, {},
		{ 1, 2, 0, 3 }, {}, { 1, 3, 0, 2 }, {}, {}, {}, { 2, 3, 0, 1 }, { 2, 3, 1 },
		{ 1, 0, 2, 3 }, { 1, 0, 3, 2 }, {}, {}, {}, { 2, 0, 3, 1 }, {}, { 2, 1, 3 },
		{}, {}, {}, {}, {}, {}, {}, {},
		{ 2, 0, 1, 3 }, {}, {}, {}, { 3, 0, 1, 2 }, { 3, 0, 2, 1 }, {}, { 3, 1, 2 },
		{ 2, 1, 0, 3 }, {}, {}, {}, { 3, 1, 0, 2 }, {}, { 3, 2, 0, 1 }, { 3, 2, 1 }
	)

	-- Convert the above indices to masks that can be shifted / anded into offsets --
	for i = 0, 63 do
		Simplex\[i\]\[0\] = lshift(1, Simplex\[i\]\[0\]) - 1
		Simplex\[i\]\[1\] = lshift(1, Simplex\[i\]\[1\]) - 1
		Simplex\[i\]\[2\] = lshift(1, Simplex\[i\]\[2\]) - 1
		Simplex\[i\]\[3\] = lshift(1, Simplex\[i\]\[3\]) - 1
	end

	---
	-- @param x
	-- @param y
	-- @param z
	-- @param w
	-- @return Noise value in the range \[-1, +1\]
	function M.Simplex4D (x, y, z, w)
		--\[\[
			4D skew factors:
			F = (math.sqrt(5) - 1) / 4 
			G = (5 - math.sqrt(5)) / 20
			G2 = 2 * G
			G3 = 3 * G
			G4 = 4 * G - 1
		\]\]

		-- Skew the input space to determine which simplex cell we are in.
		local s = (x + y + z + w) * 0.309016994 -- F
		local ix, iy, iz, iw = floor(x + s), floor(y + s), floor(z + s), floor(w + s)

		-- Unskew the cell origin back to (x, y, z) space.
		local t = (ix + iy + iz + iw) * 0.138196601 -- G
		local x0 = x + t - ix
		local y0 = y + t - iy
		local z0 = z + t - iz
		local w0 = w + t - iw

		-- For the 4D case, the simplex is a 4D shape I won't even try to describe.
		-- To find out which of the 24 possible simplices we're in, we need to
		-- determine the magnitude ordering of x0, y0, z0 and w0.
		-- The method below is a good way of finding the ordering of x,y,z,w and
		-- then find the correct traversal order for the simplex we�re in.
		-- First, six pair-wise comparisons are performed between each possible pair
		-- of the four coordinates, and the results are used to add up binary bits
		-- for an integer index.
		local c1 = band(rshift(floor(y0 - x0), 26), 32)
		local c2 = band(rshift(floor(z0 - x0), 27), 16)
		local c3 = band(rshift(floor(z0 - y0), 28), 8)
		local c4 = band(rshift(floor(w0 - x0), 29), 4)
		local c5 = band(rshift(floor(w0 - y0), 30), 2)
		local c6 = rshift(floor(w0 - z0), 31)

		-- Simplex\[c\] is a 4-vector with the numbers 0, 1, 2 and 3 in some order.
		-- Many values of c will never occur, since e.g. x>y>z>w makes x<z, y<w and x<w
		-- impossible. Only the 24 indices which have non-zero entries make any sense.
		-- We use a thresholding to set the coordinates in turn from the largest magnitude.
		local c = c1 + c2 + c3 + c4 + c5 + c6

		-- The number 3 (i.e. bit 2) in the "simplex" array is at the position of the largest coordinate.
		local i1 = rshift(Simplex\[c\]\[0\], 2)
		local j1 = rshift(Simplex\[c\]\[1\], 2)
		local k1 = rshift(Simplex\[c\]\[2\], 2)
		local l1 = rshift(Simplex\[c\]\[3\], 2)

		-- The number 2 (i.e. bit 1) in the "simplex" array is at the second largest coordinate.
		local i2 = band(rshift(Simplex\[c\]\[0\], 1), 1)
		local j2 = band(rshift(Simplex\[c\]\[1\], 1), 1)
		local k2 = band(rshift(Simplex\[c\]\[2\], 1), 1)
		local l2 = band(rshift(Simplex\[c\]\[3\], 1), 1)

		-- The number 1 (i.e. bit 0) in the "simplex" array is at the second smallest coordinate.
		local i3 = band(Simplex\[c\]\[0\], 1)
		local j3 = band(Simplex\[c\]\[1\], 1)
		local k3 = band(Simplex\[c\]\[2\], 1)
		local l3 = band(Simplex\[c\]\[3\], 1)

		-- Work out the hashed gradient indices of the five simplex corners
		-- Sum up and scale the result to cover the range \[-1,1\]
		ix, iy, iz, iw = band(ix, 255), band(iy, 255), band(iz, 255), band(iw, 255)

		local n0 = GetN(ix, iy, iz, iw, x0, y0, z0, w0)
		local n1 = GetN(ix + i1, iy + j1, iz + k1, iw + l1, x0 + 0.138196601 - i1, y0 + 0.138196601 - j1, z0 + 0.138196601 - k1, w0 + 0.138196601 - l1) -- G
		local n2 = GetN(ix + i2, iy + j2, iz + k2, iw + l2, x0 + 0.276393202 - i2, y0 + 0.276393202 - j2, z0 + 0.276393202 - k2, w0 + 0.276393202 - l2) -- G2
		local n3 = GetN(ix + i3, iy + j3, iz + k3, iw + l3, x0 + 0.414589803 - i3, y0 + 0.414589803 - j3, z0 + 0.414589803 - k3, w0 + 0.414589803 - l3) -- G3
		local n4 = GetN(ix + 1, iy + 1, iz + 1, iw + 1, x0 - 0.447213595, y0 - 0.447213595, z0 - 0.447213595, w0 - 0.447213595) -- G4

		return 2.210600293 * (n0 + n1 + n2 + n3 + n4)
	end
end

-- Export the module.
return M
]]):gsub('\\([%]%[])','%1')
sources["hate.cpml.modules.quat"]=([[-- <pack hate.cpml.modules.quat> --
-- quaternions
-- Author: Andrew Stacey
-- Website: http://www.math.ntnu.no/~stacey/HowDidIDoThat/iPad/Codea.html
-- Licence: CC0 http://wiki.creativecommons.org/CC0

--\[\[
This is a class for handling quaternion numbers.  It was originally
designed as a way of encoding rotations of 3 dimensional space.
--\]\]

local current_folder = (...):gsub('%.\[^%.\]+$', '') .. "."
local constants      = require(current_folder .. "constants")
local vec3           = require(current_folder .. "vec3")
local quaternion     = {}
quaternion.__index   = quaternion

--\[\[
A quaternion can either be specified by giving the four coordinates as
real numbers or by giving the scalar part and the vector part.
--\]\]

local function new(...)
	local x, y, z, w
	-- copy
	local arg = {...}
	if #arg == 1 and type(arg\[1\]) == "table" then
		x = arg\[1\].x
		y = arg\[1\].y
		z = arg\[1\].z
		w = arg\[1\].w
	-- four numbers
	elseif #arg == 4 then
		x = arg\[1\]
		y = arg\[2\]
		z = arg\[3\]
		w = arg\[4\]
	-- real number plus vector
	elseif #arg == 2 then
		x = arg\[1\].x or arg\[1\]\[1\]
		y = arg\[1\].y or arg\[1\]\[2\]
		z = arg\[1\].z or arg\[1\]\[3\]
		w = arg\[2\]
	else
		error("Incorrect number of arguments to quaternion")
	end

	return setmetatable({ x = x or 0, y = y or 0, z = z or 0, w = w or 0 }, quaternion)
end

function quaternion:__add(q)
	if type(q) == "number" then
		return new(self.x, self.y, self.z, self.w + q)
	else
		return new(self.x + q.x, self.y + q.y, self.z + q.z, self.w + q.w)
	end
end

function quaternion:__sub(q)
	return new(self.x - q.x, self.y - q.y, self.z - q.z, self.w - q.w)
end

function quaternion:__unm()
	return self:scale(-1)
end

function quaternion:__mul(q)
	if type(q) == "number" then
		return self:scale(q)
	elseif type(q) == "table" then
		local x,y,z,w
		x = self.w * q.x + self.x * q.w + self.y * q.z - self.z * q.y
		y = self.w * q.y - self.x * q.z + self.y * q.w + self.z * q.x
		z = self.w * q.z + self.x * q.y - self.y * q.x + self.z * q.w
		w = self.w * q.w - self.x * q.x - self.y * q.y - self.z * q.z
		return new(x,y,z,w)
	end
end

function quaternion:__div(q)
	if type(q) == "number" then
		return self:scale(1/q)
	elseif type(q) == "table" then
		return self * q:reciprocal()
	end
end

function quaternion:__pow(n)
	if n == 0 then
		return self.unit()
	elseif n > 0 then
		return self * self^(n-1)
	elseif n < 0 then
		return self:reciprocal()^(-n)
	end
end

function quaternion:__eq(q)
	if self.x ~= q.x or self.y ~= q.y or self.z ~= q.z or self.w ~= q.w then
		return false
	end
	return true
end

function quaternion:__tostring()
	return "("..tonumber(self.x)..","..tonumber(self.y)..","..tonumber(self.z)..","..tonumber(self.w)..")"
end

function quaternion.unit()
	return new(0,0,0,1)
end

function quaternion:to_axis_angle()
	local tmp = self
	if tmp.w > 1 then
		tmp = tmp:normalize()
	end
	local angle = 2 * math.acos(tmp.w)
	local s = math.sqrt(1-tmp.w*tmp.w)
	local x, y, z
	if s < constants.FLT_EPSILON then
		x = tmp.x
		y = tmp.y
		z = tmp.z
	else
		x = tmp.x / s -- normalize axis
		y = tmp.y / s
		z = tmp.z / s
	end
	return angle, { x, y, z }
end

-- Test if we are zero
function quaternion:is_zero()
	-- are we the zero vector
	if self.x ~= 0 or self.y ~= 0 or self.z ~= 0 or self.w ~= 0 then
		return false
	end
	return true
end

-- Test if we are real
function quaternion:is_real()
	-- are we the zero vector
	if self.x ~= 0 or self.y ~= 0 or self.z ~= 0 then
		return false
	end
	return true
end

-- Test if the real part is zero
function quaternion:is_imaginary()
	-- are we the zero vector
	if self.w ~= 0 then
		return false
	end
	return true
end

-- The dot product of two quaternions
function quaternion.dot(a, b)
	return a.x * b.x + a.y * b.y + a.z * b.z + a.w * b.w
end

-- Length of a quaternion
function quaternion:len()
	return math.sqrt(self:len2())
end

-- Length squared of a quaternion
function quaternion:len2()
	return self.x * self.x + self.y * self.y + self.z * self.z + self.w * self.w
end

-- Normalize a quaternion to have length 1
function quaternion:normalize()
	if self:is_zero() then
		error("Unable to normalize a zero-length quaternion")
		return false
	end
	local l = 1/self:len()
	return self:scale(l)
end

-- Scale the quaternion
function quaternion:scale(l)
	return new(self.x * l,self.y * l,self.z * l, self.w * l)
end

-- Conjugation (corresponds to inverting a rotation)
function quaternion:conjugate()
	return new(-self.x, -self.y, -self.z, self.w)
end

-- Reciprocal: 1/q
function quaternion:reciprocal()
	if self.is_zero() then
		error("Cannot reciprocate a zero quaternion")
		return false
	end
	local q = self:conjugate()
	local l = self:len2()
	q = q:scale(1/l)
	return q
end

-- Returns the real part
function quaternion:real()
	return self.w
end

-- Returns the vector (imaginary) part as a Vec3 object
function quaternion:to_vec3()
	return vec3(self.x, self.y, self.z)
end

--\[\[
Converts a rotation to a quaternion. The first argument is the angle
to rotate, the second must specify an axis as a Vec3 object.
--\]\]

function quaternion:rotate(a,axis)
	local q,c,s
	q = new(axis, 0)
	q = q:normalize()
	c = math.cos(a)
	s = math.sin(a)
	q = q:scale(s)
	q = q + c
	return q
end

function quaternion:to_euler()
	local sqx = self.x*self.x
	local sqy = self.y*self.y
	local sqz = self.z*self.z
	local sqw = self.w*self.w

	 -- if normalised is one, otherwise is correction factor
	local unit = sqx + sqy + sqz + sqw
	local test = self.x*self.y + self.z*self.w

	local pitch, yaw, roll

	 -- singularity at north pole
	if test > 0.499*unit then
		yaw = 2 * math.atan2(self.x,self.w)
		pitch = math.pi/2
		roll = 0
		return pitch, yaw, roll
	end

	 -- singularity at south pole
	if test < -0.499*unit then
		yaw = -2 * math.atan2(self.x,self.w)
		pitch = -math.pi/2
		roll = 0
		return pitch, yaw, roll
	end
	yaw = math.atan2(2*self.y*self.w-2*self.x*self.z , sqx - sqy - sqz + sqw)
	pitch = math.asin(2*test/unit)
	roll = math.atan2(2*self.x*self.w-2*self.y*self.z , -sqx + sqy - sqz + sqw)

	return pitch, roll, yaw
end

-- http://keithmaggio.wordpress.com/2011/02/15/math-magician-lerp-slerp-and-nlerp/
-- non-normalized rotations do not work out for quats!
function quaternion.lerp(a, b, s)
	local v = a + (b - a) * s
	return v:normalize()
end

-- http://number-none.com/product/Understanding%20Slerp,%20Then%20Not%20Using%20It/
function quaternion.slerp(a, b, s)
	local function clamp(n, low, high) return math.min(math.max(n, low), high) end
	local dot = a:dot(b)

	-- http://www.gamedev.net/topic/312067-shortest-slerp-path/#entry2995591
	if dot < 0 then
		a = -a
		dot = -dot
	end

	if dot > constants.DOT_THRESHOLD then
		return quaternion.lerp(a, b, s)
	end

	clamp(dot, -1, 1)
	local theta = math.acos(dot) * s
	local c = (b - a * dot):normalize()

	return a * math.cos(theta) + c * math.sin(theta)
end

-- return quaternion
-- the module
return setmetatable({ new = new },
{ __call = function(_, ...) return new(...) end })
]]):gsub('\\([%]%[])','%1')
sources["hate.cpml.modules.color"]=([[-- <pack hate.cpml.modules.color> --
local current_folder = (...):gsub('%.\[^%.\]+$', '') .. "."
local utils = require(current_folder .. "utils")
local color = {}
local function new(r, g, b, a)
	return setmetatable({r or 0, g or 0, b or 0, a or 255}, color)
end
color.__index = color
color.__call = function(_, ...) return new(...) end

function color.invert(c)
	return new(255 - c\[1\], 255 - c\[2\], 255 - c\[3\], c\[4\])
end

function color.lighten(c, v)
	return new(
		utils.clamp(c\[1\] + v * 255, 0, 255),
		utils.clamp(c\[2\] + v * 255, 0, 255),
		utils.clamp(c\[3\] + v * 255, 0, 255),
		c\[4\]
	)
end

function color.darken(c, v)
	return new(
		utils.clamp(c\[1\] - v * 255, 0, 255),
		utils.clamp(c\[2\] - v * 255, 0, 255),
		utils.clamp(c\[3\] - v * 255, 0, 255),
		c\[4\]
	)
end

function color.mul(c, v)
	local t = {}
	for i=1,3 do
		t\[i\] = c\[i\] * v
	end
	t\[4\] = c\[4\]
	setmetatable(t, color)
	return t
end

-- directly set alpha channel
function color.alpha(c, v)
	local t = {}
	for i=1,3 do
		t\[i\] = c\[i\]
	end
	t\[4\] = v * 255
	setmetatable(t, color)
	return t
end

function color.opacity(c, v)
	local t = {}
	for i=1,3 do
		t\[i\] = c\[i\]
	end
	t\[4\] = c\[4\] * v
	setmetatable(t, color)
	return t
end

-- HSV utilities (adapted from http://www.cs.rit.edu/~ncs/color/t_convert.html)

-- hsv_to_color(hsv)
-- Converts a set of HSV values to a color. hsv is a table.
-- See also: hsv(h, s, v)
local function hsv_to_color(hsv)
	local i
	local f, q, p, t
	local r, g, b
	local h, s, v
	local a = hsv\[4\] or 255
	s = hsv\[2\]
	v = hsv\[3\]

	if s == 0 then
		return new(v, v, v, a)
	end

	h = hsv\[1\] / 60

	i = math.floor(h)
	f = h - i
	p = v * (1-s)
	q = v * (1-s*f)
	t = v * (1-s*(1-f))

	if i == 0 then     return new(v, t, p, a)
	elseif i == 1 then return new(q, v, p, a)
	elseif i == 2 then return new(p, v, t, a)
	elseif i == 3 then return new(p, q, v, a)
	elseif i == 4 then return new(t, p, v, a)
	else               return new(v, p, q, a)
	end
end

function color.from_hsv(h, s, v)
	return hsv_to_color { h, s, v, 255 }
end

function color.from_hsva(h, s, v, a)
	return hsv_to_color { h, s, v, a }
end

-- color_to_hsv(c)
-- Takes in a normal color and returns a table with the HSV values.
local function color_to_hsv(c)
	local r = c\[1\]
	local g = c\[2\]
	local b = c\[3\]
	local a = c\[4\] or 255

	local h = 0
	local s = 0
	local v = 0

	local min = math.min(r, g, b)
	local max = math.max(r, g, b)
	v = max

	local delta = max - min

	-- black, nothing else is really possible here.
	if min == 0 and max == 0 then
		return { 0, 0, 0, a }
	end

	if max ~= 0 then
		s = delta / max
	else
		-- r = g = b = 0 s = 0, v is undefined
		s = 0
		h = -1
		return { h, s, v, 255 }
	end

	if r == max then
		h = ( g - b ) / delta     -- yellow/magenta
	elseif g == max then
		h = 2 + ( b - r ) / delta -- cyan/yellow
	else
		h = 4 + ( r - g ) / delta -- magenta/cyan
	end

	h = h * 60 -- degrees

	if h < 0 then
		h = h + 360
	end

	return { h, s, v, a }
end

function color.hue(color, newHue)
	local c = color_to_hsv(color)
	c\[1\] = (newHue + 360) % 360
	return hsv_to_color(c)
end

function color.saturation(color, percent)
	local c = color_to_hsv(color)
	c\[2\] = utils.clamp(percent, 0, 1)
	return hsv_to_color(c)
end

function color.value(color, percent)
	local c = color_to_hsv(color)
	c\[3\] = utils.clamp(percent, 0, 1)
	return hsv_to_color(c)
end

-- http://en.wikipedia.org/wiki/SRGB#The_reverse_transformation
function color.gamma_to_linear(r, g, b, a)
	local function convert(c)
		if c > 1.0 then
			return 1.0
		elseif c < 0.0 then
			return 0.0
		elseif c <= 0.04045 then
			return c / 12.92
		else
			return math.pow((c + 0.055) / 1.055, 2.4)
		end
	end
	if type(r) == "table" then
		local c = {}
		for i=1,3 do
			c\[i\] = convert(r\[i\] / 255) * 255
		end
		c\[4\] = convert(r\[4\] / 255) * 255
		return c
	else
		return convert(r / 255) * 255, convert(g / 255) * 255, convert(b / 255) * 255, a or 255
	end
end

-- http://en.wikipedia.org/wiki/SRGB#The_forward_transformation_.28CIE_xyY_or_CIE_XYZ_to_sRGB.29
function color.linear_to_gamma(r, g, b, a)
	local function convert(c)
		if c > 1.0 then
			return 1.0
		elseif c < 0.0 then
			return 0.0
		elseif c < 0.0031308 then
			return c * 12.92
		else
			return 1.055 * math.pow(c, 0.41666) - 0.055
		end
	end
	if type(r) == "table" then
		local c = {}
		for i=1,3 do
			c\[i\] = convert(r\[i\] / 255) * 255
		end
		c\[4\] = convert(r\[4\] / 255) * 255
		return c
	else
		return convert(r / 255) * 255, convert(g / 255) * 255, convert(b / 255) * 255, a or 255
	end
end

return setmetatable({new = new}, color)
]]):gsub('\\([%]%[])','%1')
sources["hate.cpml.modules.mat4"]=([[-- <pack hate.cpml.modules.mat4> --
-- double 4x4, 1-based, column major
-- local matrix = {}

local current_folder = (...):gsub('%.\[^%.\]+$', '') .. "."
local constants = require(current_folder .. "constants")
local vec3 = require(current_folder .. "vec3")

local mat4 = {}
mat4.__index = mat4
setmetatable(mat4, mat4)

-- from https://github.com/davidm/lua-matrix/blob/master/lua/matrix.lua
-- Multiply two matrices; m1 columns must be equal to m2 rows
-- e.g. #m1\[1\] == #m2
local function matrix_mult_nxn(m1, m2)
	local mtx = {}
	for i = 1, #m1 do
		mtx\[i\] = {}
		for j = 1, #m2\[1\] do
			local num = m1\[i\]\[1\] * m2\[1\]\[j\]
			for n = 2, #m1\[1\] do
				num = num + m1\[i\]\[n\] * m2\[n\]\[j\]
			end
			mtx\[i\]\[j\] = num
		end
	end
	return mtx
end

function mat4:__call(v)
	local m = {
		1, 0, 0, 0,
		0, 1, 0, 0,
		0, 0, 1, 0,
		0, 0, 0, 1
	}
	if type(v) == "table" and #v == 16 then
		for i=1,16 do
			m\[i\] = v\[i\]
		end
	elseif type(v) == "table" and #v == 9 then
		m\[1\], m\[2\], m\[3\] = v\[1\], v\[2\], v\[3\]
		m\[5\], m\[6\], m\[7\] = v\[4\], v\[5\], v\[6\]
		m\[9\], m\[10\], m\[11\] = v\[7\], v\[8\], v\[9\]
		m\[16\] = 1
	elseif type(v) == "table" and type(v\[1\]) == "table" then
		local idx = 1
		for i=1, 4 do
			for j=1, 4 do
				m\[idx\] = v\[i\]\[j\]
				idx = idx + 1
			end
		end
	end

	-- Look in mat4 for metamethods
	setmetatable(m, mat4)

	return m
end

function mat4:__eq(b)
	local abs = math.abs
	for i=1, 16 do
		if abs(self\[i\] - b\[i\]) > constants.FLT_EPSILON then
			return false
		end
	end
	return true
end

function mat4:__tostring()
	local str = "\[ "
	for i, v in ipairs(self) do
		str = str .. string.format("%2.5f", v)
		if i < #self then
			str = str .. ", "
		end
	end
	str = str .. " \]"
	return str
end

function mat4:ortho(left, right, top, bottom, near, far)
	local out = mat4()
	out\[1\] = 2 / (right - left)
	out\[6\] = 2 / (top - bottom)
	out\[11\] = -2 / (far - near)
	out\[13\] = -((right + left) / (right - left))
	out\[14\] = -((top + bottom) / (top - bottom))
	out\[15\] = -((far + near) / (far - near))
	out\[16\] = 1
	return out
end

function mat4:perspective(fovy, aspect, near, far)
	assert(aspect ~= 0)
	assert(near ~= far)

	local t = math.tan(fovy / 2)
	local result = mat4(
		0, 0, 0, 0,
		0, 0, 0, 0,
		0, 0, 0, 0,
		0, 0, 0, 0
	)

	result\[1\] = 1 / (aspect * t)
	result\[6\] = 1 / t
	result\[11\] = - (far + near) / (far - near)
	result\[12\] = - 1
	result\[15\] = - (2 * far * near) / (far - near)

	return result
end

function mat4:translate(t)
	local m = {
		1, 0, 0, 0,
		0, 1, 0, 0,
		0, 0, 1, 0,
		t.x, t.y, t.z, 1
	}
	return mat4(m) * mat4(self)
end

function mat4:scale(s)
	local m = {
		s.x, 0, 0, 0,
		0, s.y, 0, 0,
		0, 0, s.z, 0,
		0, 0, 0, 1
	}
	return mat4(m) * mat4(self)
end

local function len(v)
	return math.sqrt(v\[1\] * v\[1\] + v\[2\] * v\[2\] + v\[3\] * v\[3\])
end

function mat4:rotate(angle, axis)
	if type(angle) == "table" then
		angle, axis = angle:to_axis_angle()
	end
	local l = len(axis)
	if l == 0 then
		return self
	end
	local x, y, z = axis\[1\] / l, axis\[2\] / l, axis\[3\] / l
	local c = math.cos(angle)
	local s = math.sin(angle)
	local m = {
		x*x*(1-c)+c, y*x*(1-c)+z*s, x*z*(1-c)-y*s, 0,
		x*y*(1-c)-z*s, y*y*(1-c)+c, y*z*(1-c)+x*s, 0,
		x*z*(1-c)+y*s, y*z*(1-c)-x*s, z*z*(1-c)+c, 0,
		0, 0, 0, 1,
	}
	return mat4(m) * mat4(self)
end

-- Set mat4 to identity mat4. Tested OK
function mat4:identity()
	local out = mat4()
	for i=1, 16, 5 do
		out\[i\] = 1
	end
	return out
end

function mat4:clone()
	return mat4(self)
end

-- Inverse of matrix. Tested OK
function mat4:invert()
	local out = mat4()

	out\[1\] =  self\[6\]  * self\[11\] * self\[16\] -
		self\[6\]  * self\[12\] * self\[15\] -
		self\[10\] * self\[7\]  * self\[16\] +
		self\[10\] * self\[8\]  * self\[15\] +
		self\[14\] * self\[7\]  * self\[12\] -
		self\[14\] * self\[8\]  * self\[11\]

	out\[5\] = -self\[5\]  * self\[11\] * self\[16\] +
		self\[5\]  * self\[12\] * self\[15\] +
		self\[9\]  * self\[7\]  * self\[16\] -
		self\[9\]  * self\[8\]  * self\[15\] -
		self\[13\] * self\[7\]  * self\[12\] +
		self\[13\] * self\[8\]  * self\[11\]

	out\[9\] =  self\[5\]  * self\[10\] * self\[16\] -
		self\[5\]  * self\[12\] * self\[14\] -
		self\[9\]  * self\[6\]  * self\[16\] +
		self\[9\]  * self\[8\]  * self\[14\] +
		self\[13\] * self\[6\]  * self\[12\] -
		self\[13\] * self\[8\]  * self\[10\]

	out\[13\] = -self\[5\]  * self\[10\] * self\[15\] +
		self\[5\]  * self\[11\] * self\[14\] +
		self\[9\]  * self\[6\]  * self\[15\] -
		self\[9\]  * self\[7\]  * self\[14\] -
		self\[13\] * self\[6\]  * self\[11\] +
		self\[13\] * self\[7\]  * self\[10\]

	out\[2\] = -self\[2\]  * self\[11\] * self\[16\] +
		self\[2\]  * self\[12\] * self\[15\] +
		self\[10\] * self\[3\]  * self\[16\] -
		self\[10\] * self\[4\]  * self\[15\] -
		self\[14\] * self\[3\]  * self\[12\] +
		self\[14\] * self\[4\]  * self\[11\]

	out\[6\] =  self\[1\]  * self\[11\] * self\[16\] -
		self\[1\]  * self\[12\] * self\[15\] -
		self\[9\]  * self\[3\] * self\[16\] +
		self\[9\]  * self\[4\] * self\[15\] +
		self\[13\] * self\[3\] * self\[12\] -
		self\[13\] * self\[4\] * self\[11\]

	out\[10\] = -self\[1\]  * self\[10\] * self\[16\] +
		self\[1\]  * self\[12\] * self\[14\] +
		self\[9\]  * self\[2\]  * self\[16\] -
		self\[9\]  * self\[4\]  * self\[14\] -
		self\[13\] * self\[2\]  * self\[12\] +
		self\[13\] * self\[4\]  * self\[10\]

	out\[14\] = self\[1\]  * self\[10\] * self\[15\] -
		self\[1\]  * self\[11\] * self\[14\] -
		self\[9\]  * self\[2\] * self\[15\] +
		self\[9\]  * self\[3\] * self\[14\] +
		self\[13\] * self\[2\] * self\[11\] -
		self\[13\] * self\[3\] * self\[10\]

	out\[3\] = self\[2\]  * self\[7\] * self\[16\] -
		self\[2\]  * self\[8\] * self\[15\] -
		self\[6\]  * self\[3\] * self\[16\] +
		self\[6\]  * self\[4\] * self\[15\] +
		self\[14\] * self\[3\] * self\[8\] -
		self\[14\] * self\[4\] * self\[7\]

	out\[7\] = -self\[1\]  * self\[7\] * self\[16\] +
		self\[1\]  * self\[8\] * self\[15\] +
		self\[5\]  * self\[3\] * self\[16\] -
		self\[5\]  * self\[4\] * self\[15\] -
		self\[13\] * self\[3\] * self\[8\] +
		self\[13\] * self\[4\] * self\[7\]

	out\[11\] = self\[1\]  * self\[6\] * self\[16\] -
		self\[1\]  * self\[8\] * self\[14\] -
		self\[5\]  * self\[2\] * self\[16\] +
		self\[5\]  * self\[4\] * self\[14\] +
		self\[13\] * self\[2\] * self\[8\] -
		self\[13\] * self\[4\] * self\[6\]

	out\[15\] = -self\[1\]  * self\[6\] * self\[15\] +
		self\[1\]  * self\[7\] * self\[14\] +
		self\[5\]  * self\[2\] * self\[15\] -
		self\[5\]  * self\[3\] * self\[14\] -
		self\[13\] * self\[2\] * self\[7\] +
		self\[13\] * self\[3\] * self\[6\]

	out\[4\] = -self\[2\]  * self\[7\] * self\[12\] +
		self\[2\]  * self\[8\] * self\[11\] +
		self\[6\]  * self\[3\] * self\[12\] -
		self\[6\]  * self\[4\] * self\[11\] -
		self\[10\] * self\[3\] * self\[8\] +
		self\[10\] * self\[4\] * self\[7\]

	out\[8\] = self\[1\] * self\[7\] * self\[12\] -
		self\[1\] * self\[8\] * self\[11\] -
		self\[5\] * self\[3\] * self\[12\] +
		self\[5\] * self\[4\] * self\[11\] +
		self\[9\] * self\[3\] * self\[8\] -
		self\[9\] * self\[4\] * self\[7\]

	out\[12\] = -self\[1\] * self\[6\] * self\[12\] +
		self\[1\] * self\[8\] * self\[10\] +
		self\[5\] * self\[2\] * self\[12\] -
		self\[5\] * self\[4\] * self\[10\] -
		self\[9\] * self\[2\] * self\[8\] +
		self\[9\] * self\[4\] * self\[6\]

	out\[16\] = self\[1\] * self\[6\] * self\[11\] -
		self\[1\] * self\[7\] * self\[10\] -
		self\[5\] * self\[2\] * self\[11\] +
		self\[5\] * self\[3\] * self\[10\] +
		self\[9\] * self\[2\] * self\[7\] -
		self\[9\] * self\[3\] * self\[6\]

	local det = self\[1\] * out\[1\] + self\[2\] * out\[5\] + self\[3\] * out\[9\] + self\[4\] * out\[13\]

	if det == 0 then return self end

	det = 1.0 / det

	for i = 1, 16 do
		out\[i\] = out\[i\] * det
	end

	return out
end

-- https://github.com/g-truc/glm/blob/master/glm/gtc/matrix_transform.inl#L317
-- Note: GLM calls the view matrix "model"
function mat4.project(obj, view, projection, viewport)
	local position = { obj.x, obj.y, obj.z, 1 }

	position = view:transpose() * position
	position = projection:transpose() * position

	position\[1\] = position\[1\] / position\[4\] * 0.5 + 0.5
	position\[2\] = position\[2\] / position\[4\] * 0.5 + 0.5
	position\[3\] = position\[3\] / position\[4\] * 0.5 + 0.5
	position\[4\] = position\[4\] / position\[4\] * 0.5 + 0.5

	position\[1\] = position\[1\] * viewport\[3\] + viewport\[1\]
	position\[2\] = position\[2\] * viewport\[4\] + viewport\[2\]

	return vec3(position\[1\], position\[2\], position\[3\])
end

-- https://github.com/g-truc/glm/blob/master/glm/gtc/matrix_transform.inl#L338
-- Note: GLM calls the view matrix "model"
function mat4.unproject(win, view, projection, viewport)
	local inverse = (projection:transpose() * view:transpose()):invert()
	local position = { win.x, win.y, win.z, 1 }
	position\[1\] = (position\[1\] - viewport\[1\]) / viewport\[3\]
	position\[2\] = (position\[2\] - viewport\[2\]) / viewport\[4\]

	position\[1\] = position\[1\] * 2 - 1
	position\[2\] = position\[2\] * 2 - 1
	position\[3\] = position\[3\] * 2 - 1
	position\[4\] = position\[4\] * 2 - 1

	position = inverse * position

	position\[1\] = position\[1\] / position\[4\]
	position\[2\] = position\[2\] / position\[4\]
	position\[3\] = position\[3\] / position\[4\]
	position\[4\] = position\[4\] / position\[4\]

	return vec3(position\[1\], position\[2\], position\[3\])
end

function mat4:look_at(eye, center, up)
	local forward = (center - eye):normalize()
	local side = forward:cross(up):normalize()
	local new_up = side:cross(forward):normalize()

	local view = mat4()
	view\[1\]	= side.x
	view\[5\]	= side.y
	view\[9\]	= side.z

	view\[2\]	= new_up.x
	view\[6\]	= new_up.y
	view\[10\]= new_up.z

	view\[3\]	= -forward.x
	view\[7\]	= -forward.y
	view\[11\]= -forward.z

	view\[16\]= 1

	-- Fix 1u offset
	local new_eye = eye + forward

	local out = mat4():translate(-new_eye) * view
	return out * self
end


function mat4:transpose()
	local m = {
		self\[1\], self\[5\], self\[9\], self\[13\],
		self\[2\], self\[6\], self\[10\], self\[14\],
		self\[3\], self\[7\], self\[11\], self\[15\],
		self\[4\], self\[8\], self\[12\], self\[16\]
	}
	return mat4(m)
end

function mat4:__unm()
	return self:invert()
end

-- Multiply mat4 by a mat4. Tested OK
function mat4:__mul(m)
	if #m == 4 then
		local tmp = matrix_mult_nxn(self:to_vec4s(), { {m\[1\]}, {m\[2\]}, {m\[3\]}, {m\[4\]} })
		local v = {}
		for i=1, 4 do
			v\[i\] = tmp\[i\]\[1\]
		end
		return v
	end

	local out = mat4()
	for i=0, 12, 4 do
		for j=1, 4 do
			out\[i+j\] = m\[j\] * self\[i+1\] + m\[j+4\] * self\[i+2\] + m\[j+8\] * self\[i+3\] + m\[j+12\] * self\[i+4\]
		end
	end
	return out
end

function mat4:to_vec4s()
	return {
		{ self\[1\], self\[2\], self\[3\], self\[4\] },
		{ self\[5\], self\[6\], self\[7\], self\[8\] },
		{ self\[9\], self\[10\], self\[11\], self\[12\] },
		{ self\[13\], self\[14\], self\[15\], self\[16\] }
	}
end

return mat4
]]):gsub('\\([%]%[])','%1')
sources["hate.cpml.modules.vec2"]=([[-- <pack hate.cpml.modules.vec2> --
--\[\[
Copyright (c) 2010-2013 Matthias Richter

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

Except as contained in this notice, the name(s) of the above copyright holders
shall not be used in advertising or otherwise to promote the sale, use or
other dealings in this Software without prior written authorization.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.
\]\]--

local assert = assert
local sqrt, cos, sin, atan2 = math.sqrt, math.cos, math.sin, math.atan2

local vector = {}
vector.__index = vector

local function new(x,y)
	return setmetatable({x = x or 0, y = y or 0}, vector)
end
local zero = new(0,0)

local function isvector(v)
	return type(v) == 'table' and type(v.x) == 'number' and type(v.y) == 'number'
end

function vector:clone()
	return new(self.x, self.y)
end

function vector:unpack()
	return self.x, self.y
end

function vector:__tostring()
	return "("..tonumber(self.x)..","..tonumber(self.y)..")"
end

function vector.__unm(a)
	return new(-a.x, -a.y)
end

function vector.__add(a,b)
	assert(isvector(a) and isvector(b), "Add: wrong argument types (<vector> expected)")
	return new(a.x+b.x, a.y+b.y)
end

function vector.__sub(a,b)
	assert(isvector(a) and isvector(b), "Sub: wrong argument types (<vector> expected)")
	return new(a.x-b.x, a.y-b.y)
end

function vector.__mul(a,b)
	if type(a) == "number" then
		return new(a*b.x, a*b.y)
	elseif type(b) == "number" then
		return new(b*a.x, b*a.y)
	else
		assert(isvector(a) and isvector(b), "Mul: wrong argument types (<vector> or <number> expected)")
		return a.x*b.x + a.y*b.y
	end
end

function vector.__div(a,b)
	assert(isvector(a) and type(b) == "number", "wrong argument types (expected <vector> / <number>)")
	return new(a.x / b, a.y / b)
end

function vector.__eq(a,b)
	return a.x == b.x and a.y == b.y
end

function vector.__lt(a,b)
	return a.x < b.x or (a.x == b.x and a.y < b.y)
end

function vector.__le(a,b)
	return a.x <= b.x and a.y <= b.y
end

function vector.permul(a,b)
	assert(isvector(a) and isvector(b), "permul: wrong argument types (<vector> expected)")
	return new(a.x*b.x, a.y*b.y)
end

function vector:len2()
	return self.x * self.x + self.y * self.y
end

function vector:len()
	return sqrt(self.x * self.x + self.y * self.y)
end

function vector.dist(a, b)
	assert(isvector(a) and isvector(b), "dist: wrong argument types (<vector> expected)")
	local dx = a.x - b.x
	local dy = a.y - b.y
	return sqrt(dx * dx + dy * dy)
end

function vector.dist2(a, b)
	assert(isvector(a) and isvector(b), "dist: wrong argument types (<vector> expected)")
	local dx = a.x - b.x
	local dy = a.y - b.y
	return (dx * dx + dy * dy)
end

function vector:normalize_inplace()
	local l = self:len()
	if l > 0 then
		self.x, self.y = self.x / l, self.y / l
	end
	return self
end

function vector:normalize()
	return self:clone():normalize_inplace()
end

function vector:rotate_inplace(phi)
	local c, s = cos(phi), sin(phi)
	self.x, self.y = c * self.x - s * self.y, s * self.x + c * self.y
	return self
end

function vector:rotate(phi)
	local c, s = cos(phi), sin(phi)
	return new(c * self.x - s * self.y, s * self.x + c * self.y)
end

function vector:perpendicular()
	return new(-self.y, self.x)
end

function vector:project_on(v)
	assert(isvector(v), "invalid argument: cannot project vector on " .. type(v))
	-- (self * v) * v / v:len2()
	local s = (self.x * v.x + self.y * v.y) / (v.x * v.x + v.y * v.y)
	return new(s * v.x, s * v.y)
end

function vector:mirror_on(v)
	assert(isvector(v), "invalid argument: cannot mirror vector on " .. type(v))
	-- 2 * self:projectOn(v) - self
	local s = 2 * (self.x * v.x + self.y * v.y) / (v.x * v.x + v.y * v.y)
	return new(s * v.x - self.x, s * v.y - self.y)
end

function vector:cross(v)
	assert(isvector(v), "cross: wrong argument types (<vector> expected)")
	return self.x * v.y - self.y * v.x
end

-- ref.: http://blog.signalsondisplay.com/?p=336
function vector:trim_inplace(maxLen)
	local s = maxLen * maxLen / self:len2()
	s = (s > 1 and 1) or math.sqrt(s)
	self.x, self.y = self.x * s, self.y * s
	return self
end

function vector:angle_to(other)
	if other then
		return atan2(self.y, self.x) - atan2(other.y, other.x)
	end
	return atan2(self.y, self.x)
end

function vector:trim(maxLen)
	return self:clone():trim_inplace(maxLen)
end


-- the module
return setmetatable({new = new, isvector = isvector, zero = zero},
{__call = function(_, ...) return new(...) end})
]]):gsub('\\([%]%[])','%1')
sources["hate.cpml.modules.mesh"]=([[-- <pack hate.cpml.modules.mesh> --
local current_folder = (...):gsub('%.\[^%.\]+$', '') .. "."
local vec3 = require(current_folder .. "vec3")

local mesh = {}

function mesh.compute_normal(a, b, c)
	return (c - a):cross(b - a):normalize()
end

function mesh.average(vertices)
	local avg = vec3(0,0,0)
	for _, v in ipairs(vertices) do
		avg = avg + v
	end
	return avg / #vertices
end

return mesh
]]):gsub('\\([%]%[])','%1')
sources["hate.cpml.modules.utils"]=([[-- <pack hate.cpml.modules.utils> --
local utils = {}

function utils.clamp(v, min, max)
	return math.max(math.min(v, max), min)
end

function utils.map(v, min_in, max_in, min_out, max_out)
	return ((v) - (min_in)) * ((max_out) - (min_out)) / ((max_in) - (min_in)) + (min_out)
end

function utils.lerp(v, l, h)
	return v * (h - l) + l
end

function utils.round(v, precision)
	if precision then return utils.round(v / precision) * precision end
	return v >= 0 and math.floor(v+0.5) or math.ceil(v-0.5)
end

function utils.wrap(v, n)
	if v < 0 then
		v = v + utils.round(((-v/n)+1))*n
	end
	return v % n
end

-- from undef: https://love2d.org/forums/viewtopic.php?p=182219#p182219
-- check if a number is a power-of-two
function utils.is_pot(n)
  return 0.5 == (math.frexp(n))
end

return utils
]]):gsub('\\([%]%[])','%1')
sources["hate.cpml.init"]=([[-- <pack hate.cpml.init> --
--\[\[
                  .'@@@@@@@@@@@@@@#:
              ,@@@@#;            .'@@@@+
           ,@@@'                      .@@@#
         +@@+            ....            .@@@
       ;@@;         '@@@@@@@@@@@@.          @@@
      @@#         @@@@@@@@++@@@@@@@;         `@@;
    .@@`         @@@@@#        #@@@@@          @@@
   `@@          @@@@@` Cirno's  `@@@@#          +@@
   @@          `@@@@@  Perfect   @@@@@           @@+
  @@+          ;@@@@+   Math     +@@@@+           @@
  @@           `@@@@@  Library   @@@@@@           #@'
 `@@            @@@@@@          @@@@@@@           `@@
 :@@             #@@@@@@.    .@@@@@@@@@            @@
 .@@               #@@@@@@@@@@@@;;@@@@@            @@
  @@                  .;+@@#'.   ;@@@@@           :@@
  @@`                            +@@@@+           @@.
  ,@@                            @@@@@           .@@
   @@#          ;;;;;.          `@@@@@           @@
    @@+         .@@@@@          @@@@@           @@`
     #@@         '@@@@@#`    ;@@@@@@          ;@@
      .@@'         @@@@@@@@@@@@@@@           @@#
        +@@'          '@@@@@@@;            @@@
          '@@@`                         '@@@
             #@@@;                  .@@@@:
                :@@@@@@@++;;;+#@@@@@@+`
                      .;'+++++;.
--\]\]
local current_folder = (...):gsub('%.init$', '') .. "."

local cpml = {
	_LICENSE = "CPML is distributed under the terms of the MIT license. See LICENSE.md.",
	_URL = "https://github.com/shakesoda/cpml",
	_VERSION = "0.0.9",
	_DESCRIPTION = "Cirno's Perfect Math Library: Just about everything you need for 3D games. Hopefully."
}

local files = {
	"color",
	"constants",
	"intersect",
	"mat4",
	"mesh",
	"octree",
	"quadtree",
	"quat",
	"simplex",
	"utils",
	"vec2",
	"vec3",
}

for _, v in ipairs(files) do
	cpml\[v\] = require(current_folder .. "modules." .. v)
end

return cpml
]]):gsub('\\([%]%[])','%1')
sources["hate.timer"]=([[-- <pack hate.timer> --
local current_folder = (...):gsub('%.\[^%.\]+$', '') .. "."
local sdl = require(current_folder .. "sdl2")

local timer = {}

local last
local last_delta = 0
local average_delta = 0
local delta_list = {}

function timer.init()
	timer.step()
end

function timer.step()
	local now = tonumber(sdl.getPerformanceCounter())

	if not last then
		last = now
	end

	local freq = tonumber(sdl.getPerformanceFrequency())

	local delta = (now - last) / freq

	table.insert(
		delta_list,
		{ delta, now }
	)

	-- we only want to average everything from the last second
	local first_delta = (now - delta_list\[1\]\[2\]) / freq
	if first_delta > 1 then
		table.remove(delta_list, 1)

		local average = 0
		for i=1,#delta_list do
			average = average + delta_list\[i\]\[1\]
		end
		average = (average / #delta_list)

		average_delta = average
	else
		-- the average will be trash for the first second - so don't use it.
		average_delta = delta
	end

	-- print(average_delta)

	last_delta = delta_list\[#delta_list\]\[1\]

	last = now
end

function timer.getDelta()
	return tonumber(last_delta)
end

function timer.sleep(seconds)
	sdl.delay(seconds * 1000)
end

function timer.getAverageDelta()
	return tonumber(average_delta)
end

function timer.getTime()
	return tonumber(last / sdl.getPerformanceFrequency())
end

function timer.getFPS()
	return math.ceil(1 / average_delta * 100) / 100
end

return timer
]]):gsub('\\([%]%[])','%1')
sources["hate.physfs"]=([[-- <pack hate.physfs> --
local ffi = require "ffi"
local cdef = ffi.cdef(\[\[
typedef unsigned char PHYSFS_uint8;
typedef signed char PHYSFS_sint8;
typedef unsigned short PHYSFS_uint16;
typedef signed short PHYSFS_sint16;
typedef unsigned int PHYSFS_uint32;
typedef signed int PHYSFS_sint32;
typedef unsigned long long PHYSFS_uint64;
typedef signed long long PHYSFS_sint64;

typedef struct PHYSFS_File
{
	void *opaque;
} PHYSFS_File;

typedef struct PHYSFS_ArchiveInfo
{
	const char *extension;
	const char *description;
	const char *author;
	const char *url;
} PHYSFS_ArchiveInfo;

typedef struct PHYSFS_Version
{
	PHYSFS_uint8 major;
	PHYSFS_uint8 minor;
	PHYSFS_uint8 patch;
} PHYSFS_Version;

int PHYSFS_init(const char *argv0);
int PHYSFS_deinit(void);

PHYSFS_File *PHYSFS_openAppend(const char *filename);
PHYSFS_File *PHYSFS_openRead(const char *filename);
PHYSFS_File *PHYSFS_openWrite(const char *filename);

int PHYSFS_close(PHYSFS_File *handle);
int PHYSFS_exists(const char *fname);
int PHYSFS_seek(PHYSFS_File *handle, PHYSFS_uint64 pos);
int PHYSFS_flush(PHYSFS_File *handle);
int PHYSFS_eof(PHYSFS_File *handle);
int PHYSFS_delete(const char *filename);
PHYSFS_sint64 PHYSFS_tell(PHYSFS_File *handle);
PHYSFS_sint64 PHYSFS_write(PHYSFS_File *handle, const void *buffer, PHYSFS_uint32 objSize, PHYSFS_uint32 objCount);

int PHYSFS_mkdir(const char *dirName);
int PHYSFS_mount(const char *newDir, const char *mountPoint, int appendToPath);

char **PHYSFS_enumerateFiles(const char *dir);
const char *PHYSFS_getBaseDir(void);

char **PHYSFS_getSearchPath(void);
int PHYSFS_addToSearchPath(const char *newDir, int appendToPath);
int PHYSFS_removeFromSearchPath(const char *oldDir);

char **PHYSFS_getCdRomDirs(void);
const char *PHYSFS_getDirSeparator(void);
const char *PHYSFS_getLastError(void);
const char *PHYSFS_getMountPoint(const char *dir);
const char *PHYSFS_getRealDir(const char *filename);
const char *PHYSFS_getUserDir(void);
const char *PHYSFS_getWriteDir(void);

const PHYSFS_ArchiveInfo **PHYSFS_supportedArchiveTypes(void);

int PHYSFS_isDirectory(const char *fname);
int PHYSFS_isInit(void);
int PHYSFS_isSymbolicLink(const char *fname);

int PHYSFS_setBuffer(PHYSFS_File *handle, PHYSFS_uint64 bufsize);
int PHYSFS_setSaneConfig(const char *organization, const char *appName, const char *archiveExt, int includeCdRoms, int archivesFirst);
int PHYSFS_setWriteDir(const char *newDir);
int PHYSFS_symbolicLinksPermitted(void);


PHYSFS_sint64 PHYSFS_fileLength(PHYSFS_File *handle);
PHYSFS_sint64 PHYSFS_getLastModTime(const char *filename);
PHYSFS_sint64 PHYSFS_read(PHYSFS_File *handle, void *buffer, PHYSFS_uint32 objSize, PHYSFS_uint32 objCount);

void PHYSFS_freeList(void *listVar);
void PHYSFS_getLinkedVersion(PHYSFS_Version *ver);
void PHYSFS_permitSymbolicLinks(int allow);
\]\])

local C = ffi.load(ffi.os == "Windows" and "bin/physfs" or "physfs")
local physfs = { C = C }

local function register(luafuncname, funcname, is_string)
	local symexists, msg = pcall(function()
		local sym = C\[funcname\]
	end)
	if not symexists then
		error("Symbol " .. funcname .. " not found. Something is really, really wrong.")
	end
	-- kill the need to use ffi.string on several functions, for convenience.
	if is_string then
		physfs\[luafuncname\] = function(...)
			local r = C\[funcname\](...)
			return ffi.string(r)
		end
	else
		physfs\[luafuncname\] = C\[funcname\]
	end
end

register("init", "PHYSFS_init")
register("deinit", "PHYSFS_deinit")

register("openAppend", "PHYSFS_openAppend")
register("openRead", "PHYSFS_openRead")
register("openWrite", "PHYSFS_openWrite")

register("close", "PHYSFS_close")
register("exists", "PHYSFS_exists")
register("seek", "PHYSFS_seek")
register("flush", "PHYSFS_flush")
register("eof", "PHYSFS_eof")
register("delete", "PHYSFS_delete")
register("tell", "PHYSFS_tell")
register("write", "PHYSFS_write")

register("mkdir", "PHYSFS_mkdir")
register("mount", "PHYSFS_mount")

register("enumerateFiles", "PHYSFS_enumerateFiles")
register("getBaseDir", "PHYSFS_getBaseDir", true)

register("getSearchPath", "PHYSFS_getSearchPath")
register("addToSearchPath", "PHYSFS_addToSearchPath")
register("removeFromSearchPath", "PHYSFS_removeFromSearchPath")

register("getCdRomDirs", "PHYSFS_getCdRomDirs")
register("getDirSeparator", "PHYSFS_getDirSeparator", true)
register("getLastError", "PHYSFS_getLastError", true)
register("getMountPoint", "PHYSFS_getMountPoint", true)
register("getRealDir", "PHYSFS_getRealDir", true)
register("getUserDir", "PHYSFS_getUserDir", true)
register("getWriteDir", "PHYSFS_getWriteDir", true)

register("supportedArchiveTypes", "PHYSFS_supportedArchiveTypes")

register("isDirectory", "PHYSFS_isDirectory")
register("isInit", "PHYSFS_isInit")
register("isSymbolicLink", "PHYSFS_isSymbolicLink")

register("setBuffer", "PHYSFS_setBuffer")
register("setSaneConfig", "PHYSFS_setSaneConfig")
register("setWriteDir", "PHYSFS_setWriteDir")
register("symbolicLinksPermitted", "PHYSFS_symbolicLinksPermitted")


register("fileLength", "PHYSFS_fileLength")
register("getLastModTime", "PHYSFS_getLastModTime")
register("read", "PHYSFS_read")

register("freeList", "PHYSFS_freeList")
register("getLinkedVersion", "PHYSFS_getLinkedVersion")
register("permitSymbolicLinks", "PHYSFS_permitSymbolicLinks")

return physfs
]]):gsub('\\([%]%[])','%1')
sources["hate.math"]=([[-- <pack hate.math> --
local current_folder = (...):gsub('%.\[^%.\]+$', '') .. "."
local cpml = require(current_folder .. "cpml")

local math = {}

-- CPML's functions have the same semantics as LOVE here - no extra work needed
function math.linearToGamma(...)
	return cpml.color.linear_to_gamma(...)
end

function math.gammaToLinear(...)
	return cpml.color.gamma_to_linear(...)
end

return math
]]):gsub('\\([%]%[])','%1')
sources["hate.init"]=([[-- <pack hate.init> --
local current_folder = (...):gsub('%.\[^%.\]+$', '') .. "."

local ffi = require "ffi"
local sdl = require(current_folder .. "sdl2")
local opengl = require(current_folder .. "opengl")

local flags

local hate = {
	_LICENSE = "HATE is distributed under the terms of the MIT license. See LICENSE.md.",
	_URL = "https://github.com/excessive/hate",
	_VERSION_MAJOR = 0,
	_VERSION_MINOR = 0,
	_VERSION_REVISION = 1,
	_VERSION_CODENAME = "Tsubasa",
	_DESCRIPTION = "It's not LÖVE."
}

hate._VERSION = string.format(
	"%d.%d.%d",
	hate._VERSION_MAJOR,
	hate._VERSION_MINOR,
	hate._VERSION_REVISION
)

-- Set a global so that libs like lcore can detect hate.
-- (granted, most things will also have the "hate" global)
FULL_OF_HATE = hate._VERSION

local function handle_events()
	local window = hate.state.window

	local event = ffi.new("SDL_Event\[?\]", 1)
	sdl.pollEvent(event)
	event = event\[0\]

	-- No event, we're done here.
	if event.type == 0 then
		return
	end

	local function sym2str(sym)
		-- 0x20-0x7E are ASCII printable characters
		if sym >= 0x20 and sym < 0x7E then
			return string.char(sym)
		end

		local specials = {
			\[13\] = "return",
			\[27\] = "escape",
			\[8\] = "backspace",
			\[9\] = "tab",
		}

		if specials\[sym\] then
			return specials\[sym\]
		end

		print(string.format("Unhandled key %d, returning the key code.", sym))

		return sym
	end

	local handlers = {
		\[sdl.QUIT\] = function()
			hate.quit()
		end,
		\[sdl.TEXTINPUT\] = function(event)
			local e = event.text
			local t = ffi.string(e.text)
			hate.textinput(t)
		end,
		\[sdl.KEYDOWN\] = function(event)
			local e = event.key
			local key = sym2str(e.keysym.sym)
			-- e.repeat conflicts with the repeat keyword.
			hate.keypressed(key, e\["repeat"\])

			-- escape to quit by default.
			if key == "escape" then
				hate.event.quit()
			end
		end,
		\[sdl.KEYUP\] = function(event)
			local e = event.key
			local key = sym2str(e.keysym.sym)
			hate.keyreleased(key)
		end,
		\[sdl.TEXTEDITING\] = function(event)
			local e = event.edit
			-- TODO
		end,
		\[sdl.MOUSEMOTION\] = function(event) end,
		-- resize, minimize, etc.
		\[sdl.WINDOWEVENT\] = function(event)
			local window = event.window
			if window.event == sdl.WINDOWEVENT_RESIZED then
				local w, h = tonumber(window.data1), tonumber(window.data2)
				hate.resize(w, h)
			end
		end,
		\[sdl.MOUSEBUTTONDOWN\] = function(event)
			local e = event.button
			print(e.x, e.y)
		end,
		\[sdl.MOUSEBUTTONUP\] = function(event)
			local e = event.button
			print(e.x, e.y)
		end,
	}

	if handlers\[event.type\] then
		handlers\[event.type\](event)
		return
	end

	print(string.format("Unhandled event type: %s", event.type))
end

function hate.getVersion()
	return hate._VERSION_MAJOR, hate._VERSION_MINOR, hate._VERSION_REVISION, hate._VERSION_CODENAME, "HATE"
end

function hate.run()
	-- TODO: remove this.
	local config = hate.config

	if hate.math then
	--\[\[
		hate.math.setRandomSeed(os.time())

		-- first few randoms aren't good, throw them out.
		for i=1,3 do hate.math.random() end
	--\]\]
	end

	hate.load(arg)

	if hate.window then
		-- We don't want the first frame's dt to include time taken by hate.load.
		if hate.timer then hate.timer.step() end

		local dt = 0

		while true do
			hate.event.pump()
			if not hate.state.running then
				break
			end

			-- Update dt, as we'll be passing it to update
			if hate.timer then
				hate.timer.step()
				dt = hate.timer.getDelta()
			end

			-- Call update and draw
			if hate.update then hate.update(dt) end -- will pass 0 if hate.timer is disabled

			if hate.window and hate.graphics --\[\[and hate.window.isCreated()\]\] then
				hate.graphics.clear()
				hate.graphics.origin()
				if hate.draw then hate.draw() end
				hate.graphics.present()
			end

			if hate.timer then
				if hate.window and config.window.delay then
					if config.window.delay >= 0.001 then
						hate.timer.sleep(config.window.delay)
					end
				elseif hate.window then
					hate.timer.sleep(0.001)
				end
			end

			collectgarbage()
		end

		sdl.GL_MakeCurrent(hate.state.window, nil)
		sdl.GL_DeleteContext(hate.state.gl_context)
		sdl.destroyWindow(hate.state.window)
	end

	hate.quit()
end

function hate.init()
	flags = {
		gl3 = false,
		show_sdl_version = false
	}

	for _, v in ipairs(arg) do
		for k, _ in pairs(flags) do
			if v == "--" .. k then
				flags\[k\] = true
			end
		end
	end

	local callbacks = {
		"load", "quit", "conf",
		"keypressed", "keyreleased",
		"textinput", "resize"
	}

	for _, v in ipairs(callbacks) do
		local __NULL__ = function() end
		hate\[v\] = __NULL__
	end

	hate.event = {}
	hate.event.pump = handle_events
	hate.event.quit = function()
		hate.state.running = false
	end

	hate.filesystem = require(current_folder .. "filesystem")
	hate.filesystem.init(arg\[0\], "HATE")

	if hate.filesystem.exists("conf.lua") then
		xpcall(require, hate.errhand, "conf")
	end
	hate.filesystem.deinit()

	local config = {
		name       = "hate",
		window = {
			width   = 854,
			height  = 480,
			vsync   = true,
			delay   = 0.001,
			fsaa    = 0, -- for love <= 0.9.1 compatibility
			msaa    = 0,
			-- TODO: debug context + multiple attempts at creating contexts
			debug   = true,
			debug_verbose = false,
			srgb    = true,
			gl      = {
				{ 3, 3 },
				{ 2, 1 }
			}
		},
		modules = {
			math       = true,
			timer      = true,
			graphics   = true,
			system     = true,
		}
	}

	hate.conf(config)
	hate.config = config
	hate.filesystem.init(arg\[0\], hate.config.name)

	hate.state = {}
	hate.state.running = true
	hate.state.config = config

	sdl.init(sdl.INIT_EVERYTHING)

	if config.modules.math then
		hate.math = require(current_folder .. "math")
	end

	if config.modules.timer then
		hate.timer = require(current_folder .. "timer")
		hate.timer.init()
	end

	if config.modules.window then
		-- FIXME
		-- if flags.gl3 then
		-- 	sdl.GL_SetAttribute(sdl.GL_CONTEXT_MAJOR_VERSION, 3)
		-- 	sdl.GL_SetAttribute(sdl.GL_CONTEXT_MINOR_VERSION, 3)
		-- 	sdl.GL_SetAttribute(sdl.GL_CONTEXT_PROFILE_MASK, sdl.GL_CONTEXT_PROFILE_CORE)
		-- end
		if config.window.debug then
			sdl.GL_SetAttribute(sdl.GL_CONTEXT_FLAGS, sdl.GL_CONTEXT_DEBUG_FLAG)
		end
		sdl.GL_SetAttribute(sdl.GL_MULTISAMPLESAMPLES, math.max(config.window.fsaa or 0, config.window.msaa or 0))

		local window_flags = tonumber(sdl.WINDOW_OPENGL)

		if config.window.resizable then
			window_flags = bit.bor(window_flags, tonumber(sdl.WINDOW_RESIZABLE))
		end

		if config.window.vsync then
			window_flags = bit.bor(window_flags, tonumber(sdl.RENDERER_PRESENTVSYNC))
		end

		if config.window.srgb and jit.os ~= "Linux" then
			-- print(sdl.GL_FRAMEBUFFER_SRGB_CAPABLE)
			sdl.GL_SetAttribute(sdl.GL_FRAMEBUFFER_SRGB_CAPABLE, 1)
		end

		local window = sdl.createWindow(hate.config.name,
			sdl.WINDOWPOS_UNDEFINED, sdl.WINDOWPOS_UNDEFINED,
			hate.config.window.width, hate.config.window.height,
			window_flags
		)
		assert(window)

		local ctx = sdl.GL_CreateContext(window)

		assert(ctx)

		hate.state.window = window
		hate.state.gl_context = ctx

		sdl.GL_MakeCurrent(window, ctx)

		if config.window.vsync then
			if type(config.window.vsync) == "number" then
				sdl.GL_SetSwapInterval(config.window.vsync)
			else
				sdl.GL_SetSwapInterval(1)
			end
		else
			sdl.GL_SetSwapInterval(0)
		end


		opengl.loader = function(fn)
			local ptr = sdl.GL_GetProcAddress(fn)
			if flags.gl_debug then
				print(string.format("Loaded GL function: %s (%s)", fn, tostring(ptr)))
			end
			return ptr
		end
		opengl:import()

		local version = ffi.string(gl.GetString(GL.VERSION))
		local renderer = ffi.string(gl.GetString(GL.RENDERER))

		if config.window.debug then
			if gl.DebugMessageCallbackARB then
				local gl_debug_source_string = {
					\[tonumber(GL.DEBUG_SOURCE_API_ARB)\] = "API",
					\[tonumber(GL.DEBUG_SOURCE_WINDOW_SYSTEM_ARB)\] = "WINDOW_SYSTEM",
					\[tonumber(GL.DEBUG_SOURCE_SHADER_COMPILER_ARB)\] = "SHADER_COMPILER",
					\[tonumber(GL.DEBUG_SOURCE_THIRD_PARTY_ARB)\] = "THIRD_PARTY",
					\[tonumber(GL.DEBUG_SOURCE_APPLICATION_ARB)\] = "APPLICATION",
					\[tonumber(GL.DEBUG_SOURCE_OTHER_ARB)\] = "OTHER"
				}
				local gl_debug_type_string = {
					\[tonumber(GL.DEBUG_TYPE_ERROR_ARB)\] = "ERROR",
					\[tonumber(GL.DEBUG_TYPE_DEPRECATED_BEHAVIOR_ARB)\] = "DEPRECATED_BEHAVIOR",
					\[tonumber(GL.DEBUG_TYPE_UNDEFINED_BEHAVIOR_ARB)\] = "UNDEFINED_BEHAVIOR",
					\[tonumber(GL.DEBUG_TYPE_PORTABILITY_ARB)\] = "PORTABILITY",
					\[tonumber(GL.DEBUG_TYPE_PERFORMANCE_ARB)\] = "PERFORMANCE",
					\[tonumber(GL.DEBUG_TYPE_OTHER_ARB)\] = "OTHER"
				}
				local gl_debug_severity_string = {
					\[tonumber(GL.DEBUG_SEVERITY_HIGH_ARB)\] = "HIGH",
					\[tonumber(GL.DEBUG_SEVERITY_MEDIUM_ARB)\] = "MEDIUM",
					\[tonumber(GL.DEBUG_SEVERITY_LOW_ARB)\] = "LOW"
				}
				gl.DebugMessageCallbackARB(function(source, type, id, severity, length, message, userParam)
					if not hate.config.window.debug_verbose and type == GL.DEBUG_TYPE_OTHER_ARB then
						return
					end
					print(string.format("GL DEBUG source: %s type: %s id: %s severity: %s message: %q",
					gl_debug_source_string\[tonumber(source)\],
					gl_debug_type_string\[tonumber(type)\],
					tonumber(id),
					gl_debug_severity_string\[tonumber(severity)\],
					ffi.string(message)))
				end, nil)
			end
		end

		if flags.show_sdl_version then
			local v = ffi.new("SDL_version\[1\]")
			sdl.getVersion(v)
			print(string.format("SDL %d.%d.%d", v\[0\].major, v\[0\].minor, v\[0\].patch))
		end

		if flags.gl_debug then
			print(string.format("OpenGL %s on %s", version, renderer))
		end

		hate.window = require(current_folder .. "window")
		hate.window._state = hate.state

		if config.modules.graphics then
			hate.graphics = require(current_folder .. "graphics")
			hate.graphics._state = hate.state
			hate.graphics.init()
		end
	end

	if config.modules.system then
		hate.system = require(current_folder .. "system")
	end

	xpcall(require, hate.errhand, "main")

	hate.run()

	return 0
end

function hate.errhand(msg)
	msg = tostring(msg)

	local function error_printer(msg, layer)
		print((debug.traceback("Error: " .. tostring(msg), 1+(layer or 1)):gsub("\n\[^\n\]+$", "")))
	end

	error_printer(msg, 2)

	-- HATE isn't ready for this.
	if false then
		return
	end

	if not hate.window or not hate.graphics or not hate.event then
		return
	end

	if not hate.graphics.isCreated() or not hate.window.isCreated() then
		if not pcall(hate.window.setMode, 800, 600) then
			return
		end
	end

	-- Reset state.
	if hate.mouse then
		hate.mouse.setVisible(true)
		hate.mouse.setGrabbed(false)
	end
	if hate.joystick then
		for i,v in ipairs(hate.joystick.getJoysticks()) do
			v:setVibration() -- Stop all joystick vibrations.
		end
	end
	if hate.audio then hate.audio.stop() end
	hate.graphics.reset()
	hate.graphics.setBackgroundColor(89, 157, 220)
	local font = hate.graphics.setNewFont(14)

	hate.graphics.setColor(255, 255, 255, 255)

	local trace = debug.traceback()

	hate.graphics.clear()
	hate.graphics.origin()

	local err = {}

	table.insert(err, "Error\n")
	table.insert(err, msg.."\n\n")

	for l in string.gmatch(trace, "(.-)\n") do
		if not string.match(l, "boot.lua") then
			l = string.gsub(l, "stack traceback:", "Traceback\n")
			table.insert(err, l)
		end
	end

	local p = table.concat(err, "\n")

	p = string.gsub(p, "\t", "")
	p = string.gsub(p, "%\[string \"(.-)\"%\]", "%1")

	local function draw()
		hate.graphics.clear()
		hate.graphics.printf(p, 70, 70, hate.graphics.getWidth() - 70)
		hate.graphics.present()
	end

	while true do
		hate.event.pump()

		for e, a, b, c in hate.event.poll() do
			if e == "quit" then
				return
			end
			if e == "keypressed" and a == "escape" then
				return
			end
		end

		draw()

		if hate.timer then
			hate.timer.sleep(0.1)
		end
	end
end

return hate
]]):gsub('\\([%]%[])','%1')
local loadstring=loadstring; local preload = require"package".preload
for name, rawcode in pairs(sources) do preload[name]=function(...)return loadstring(rawcode)(...)end end
end;
do -- preload auto aliasing...
	local p = require("package").preload
	for k,v in pairs(p) do
		if k:find("%.init$") then
			local short = k:gsub("%.init$", "")
			if not p[short] then
				p[short] = v
			end
		end
	end
end

package.path = package.path .. ";./?/init.lua"

hate = require "hate"

return hate.init()
