#cython: profile=False
# Copyright 2004-2022 Tom Rothamel <pytom@bishoujo.us>
#
# Permission is hereby granted, free of charge, to any person
# obtaining a copy of this software and associated documentation files
# (the "Software"), to deal in the Software without restriction,
# including without limitation the rights to use, copy, modify, merge,
# publish, distribute, sublicense, and/or sell copies of the Software,
# and to permit persons to whom the Software is furnished to do so,
# subject to the following conditions:
#
# The above copyright notice and this permission notice shall be
# included in all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
# EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
# MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
# NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE
# LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION
# OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION
# WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

from __future__ import print_function

import renpy
import math
from renpy.display.matrix cimport Matrix
from renpy.display.render cimport Render, Matrix2D, render
from renpy.display.core import absolute

from sdl2 cimport *
from pygame_sdl2 cimport *

import_pygame_sdl2()

################################################################################
# Surface copying
################################################################################


def nogil_copy(src, dest):
    """
    Does a gil-less blit of src to dest, with minimal locking.
    """

    cdef SDL_Surface *src_surf
    cdef SDL_Surface *dst_surf

    src_surf = PySurface_AsSurface(src)
    dest_surf = PySurface_AsSurface(dest)

    with nogil:
        SDL_SetSurfaceBlendMode(src_surf, SDL_BLENDMODE_NONE)
        SDL_UpperBlit(src_surf, NULL, dest_surf, NULL)

################################################################################
# Transform render function
################################################################################

cdef Matrix2D IDENTITY
IDENTITY = renpy.display.render.IDENTITY


# The distance to the 1:1 plan, in the current perspective.
z11 = 0.0

# This file contains implementations of methods of classes that
# are found in other files, for performance reasons.

def transform_render(self, widtho, heighto, st, at):

    cdef double rxdx, rxdy, rydx, rydy
    cdef double cosa, sina
    cdef double xo, x1, x2, x3, px
    cdef double yo, y1, y2, y3, py
    cdef float zoom, xzoom, yzoom
    cdef double cw, ch, nw, nh
    cdef Render rv, cr, tcr
    cdef double angle
    cdef double alpha
    cdef double width = widtho
    cdef double height = heighto
    cdef double cwidth
    cdef double cheight
    cdef int xtile, ytile
    cdef int i, j

    global z11


    def make_mesh(cr):

        mr = Render(cr.width, cr.height)

        mesh_pad = state.mesh_pad

        if state.mesh_pad:

            if len(mesh_pad) == 4:
                pad_left, pad_top, pad_right, pad_bottom = mesh_pad
            else:
                pad_right, pad_bottom = mesh_pad
                pad_left = 0
                pad_top = 0

            padded = Render(cr.width + pad_left + pad_right, cr.height + pad_top + pad_bottom)
            padded.blit(cr, (pad_left, pad_top))

            cr = padded

        mr.blit(cr, (0, 0))

        mr.operation = renpy.display.render.FLATTEN
        mr.add_shader("renpy.texture")

        if isinstance(mesh, tuple):
            mesh_width, mesh_height = mesh

            mr.mesh = renpy.gl2.gl2mesh2.Mesh2.texture_grid_mesh(
                mesh_width, mesh_height,
                0.0, 0.0, cr.width, cr.height,
                0.0, 0.0, 1.0, 1.0)
        else:
            mr.mesh = True

        if blur is not None:
            mr.add_shader("-renpy.texture")
            mr.add_shader("renpy.blur")
            mr.add_uniform("u_renpy_blur_log2", math.log(blur, 2))

        return mr


    # Should we perform clipping?
    clipping = False

    # Prevent time from ticking backwards, as can happen if we replace a
    # transform but keep its state.
    if st + self.st_offset <= self.st:
        self.st_offset = self.st - st
    if at + self.at_offset <= self.at:
        self.at_offset = self.at - at

    self.st = st = st + self.st_offset
    self.at = at = at + self.at_offset

    # Update the state.
    self.update_state()

    # Render the child.
    child = self.child

    if child is None:
        child = renpy.display.transform.get_null()

    state = self.state

    xsize = state.xsize
    ysize = state.ysize
    fit = state.fit

    if xsize is not None:
        if (type(xsize) is float) and renpy.config.relative_transform_size:
            xsize *= widtho
        widtho = xsize
    if ysize is not None:
        if (type(ysize) is float) and renpy.config.relative_transform_size:
            ysize *= heighto
        heighto = ysize

    # Figure out the perspective.
    perspective = state.perspective

    if perspective is True:
        perspective = renpy.config.perspective
    elif perspective is False:
        perspective = None
    elif isinstance(perspective, (int, float)):
        perspective = (renpy.config.perspective[0], perspective, renpy.config.perspective[2])

    # Set the z11 distance.
    old_z11 = z11

    if perspective:
        z11 = perspective[1]

    cr = render(child, widtho, heighto, st - self.child_st_base, at)

    # Reset the z11 distance.
    z11 = old_z11

    cwidth = cr.width
    cheight = cr.height

    # Tile the child to make it bigger.

    xtile = state.xtile
    ytile = state.ytile

    xpan = state.xpan
    ypan = state.ypan

    if xpan is not None:
        xtile = 2

    if ypan is not None:
        ytile = 2

    if (xtile != 1) or (ytile != 1):
        tcr = renpy.display.render.Render(cwidth * xtile, cheight * ytile)

        for i in range(xtile):
            for j in range(ytile):
                tcr.blit(cr, (i * cwidth, j * cheight))

        cr = tcr

    if (xpan is not None) or (ypan is not None):

        if xpan is not None:
            xpan = (xpan % 360) / 360.0
            pan_x = cwidth * xpan
            pan_w = cwidth
        else:
            pan_x = 0
            pan_w = cr.width

        if ypan is not None:
            ypan = (ypan % 360) / 360.0
            pan_y = cheight * ypan
            pan_h = cheight
        else:
            pan_y = 0
            pan_h = cr.height

        cr = cr.subsurface((pan_x, pan_y, pan_w, pan_h))

    mesh = state.mesh
    blur = state.blur or None

    if (blur is not None) and (not mesh):
        mesh = True

    if mesh and not perspective:
        mr = cr = make_mesh(cr)

    # The width and height of the child.
    width = cr.width
    height = cr.height

    self.child_size = width, height

    # The reverse matrix.
    rxdx = 1
    rxdy = 0
    rydx = 0
    rydy = 1

    xo = 0
    yo = 0

    crop = state.crop

    # Cropping.
    if (state.corner1 is not None) and (crop is None) and (state.corner2 is not None):
        x1, y1 = state.corner1
        x2, y2 = state.corner2

        if x1 > x2:
            x3 = x1
            x1 = x2
            x2 = x3
        if y1 > y2:
            y3 = y1
            y1 = y2
            y2 = y3

        crop = (x1, y1, x2-x1, y2-y1)

    if crop is not None:

        crop_relative = state.crop_relative

        if crop_relative is None:
            crop_relative = renpy.config.crop_relative_default

        if crop_relative:
            x, y, w, h = crop

            def relative(n, base, limit):
                if isinstance(n, (int, absolute)):
                    return n
                else:
                    return min(int(n * base), limit)

            if crop_relative == "area":
                crop_xroom, crop_yroom = widtho, heighto
            else:
                crop_xroom, crop_yroom = width, height

            x = relative(x, crop_xroom, crop_xroom)
            y = relative(y, crop_yroom, crop_yroom)
            w = relative(w, crop_xroom, crop_xroom - x)
            h = relative(h, crop_yroom, crop_yroom - y)

            crop = (x, y, w, h)

        negative_xo, negative_yo, width, height = crop

        if state.rotate is not None:
            clipcr = Render(width, height)
            clipcr.subpixel_blit(cr, (-negative_xo, -negative_yo))
            clipcr.xclipping = True
            clipcr.yclipping = True
            cr = clipcr
        else:
            xo = -negative_xo
            yo = -negative_yo
            clipping = True

    # Size.
    if (width != 0) and (height != 0):
        maxsize = state.maxsize
        mul = None

        if (maxsize is not None):
            maxsizex, maxsizey = maxsize
            mul = min(maxsizex / width, maxsizey / height)

        scale = []
        if xsize is not None:
            scale.append(xsize / width)
        if ysize is not None:
            scale.append(ysize / height)

        if fit and not scale:
            scale = [widtho / width, heighto / height]

        if fit is None:
            fit = 'fill'

        if scale:
            if fit == 'scale-up':
                mul = max(1, *scale)
            elif fit == 'scale-down':
                mul = min(1, *scale)
            elif fit == 'contain':
                mul = min(scale)
            elif fit == 'cover':
                mul = max(scale)
            else:
                if xsize is None:
                    xsize = width
                if ysize is None:
                    ysize = height

        if mul is not None:
            xsize = mul * width
            ysize = mul * height

        if (xsize is not None) and (ysize is not None) and ((xsize, ysize) != (width, height)):
            nw = xsize
            nh = ysize

            xzoom = 1.0 * nw / width
            yzoom = 1.0 * nh / height

            rxdx = xzoom
            rydy = yzoom

            xo *= xzoom
            yo *= yzoom

            width = xsize
            height = ysize

    # zoom
    zoom = state.zoom
    xzoom = zoom * <double> state.xzoom
    yzoom = zoom * <double> state.yzoom

    if xzoom != 1:

        rxdx *= xzoom

        if xzoom < 0:
            width *= -xzoom
        else:
            width *= xzoom

        xo *= xzoom
        # origin corrections for flipping
        if xzoom < 0:
            xo += width

    if yzoom != 1:

        rydy *= yzoom

        if yzoom < 0:
            height *= -yzoom
        else:
            height *= yzoom

        yo *= yzoom
        # origin corrections for flipping
        if yzoom < 0:
            yo += height


    # Rotation.
    rotate = state.rotate
    if (rotate is not None) and (not perspective):

        cw = width
        ch = height

        angle = rotate * 3.1415926535897931 / 180

        cosa = math.cos(angle)
        sina = math.sin(angle)

        # reverse = Matrix2D(xdx, xdy, ydx, ydy) * reverse

        # We know that at this point, rxdy and rydx are both 0, so
        # we can simplify these formulae a bit.
        rxdy = rydy * -sina
        rydx = rxdx * sina
        rxdx *= cosa
        rydy *= cosa

        # first corner point (changes with flipping)
        px = cw / 2.0
        if xzoom < 0:
            px = -px
        py = ch / 2.0
        if yzoom < 0:
            py = -py

        if state.rotate_pad:
            width = height = math.hypot(cw, ch)

            xo = -px * cosa + py * sina
            yo = -px * sina - py * cosa

        else:
            xo = -px * cosa + py * sina
            yo = -px * sina - py * cosa

            x2 = -px * cosa - py * sina
            y2 = -px * sina + py * cosa

            x3 =  px * cosa - py * sina
            y3 =  px * sina + py * cosa

            x4 =  px * cosa + py * sina
            y4 =  px * sina - py * cosa

            width = max(xo, x2, x3, x4) - min(xo, x2, x3, x4)
            height = max(yo, y2, y3, y4) - min(yo, y2, y3, y4)

        xo += width / 2.0
        yo += height / 2.0

    rv = Render(width, height)

    if state.matrixcolor:
        matrix = state.matrixcolor

        if callable(matrix):
            matrix = matrix(None, 1.0)

        if not isinstance(matrix, renpy.display.matrix.Matrix):
            raise Exception("matrixcolor requires a Matrix (not im.matrix, got %r)" % (matrix,))

        rv.add_shader("renpy.matrixcolor")
        rv.add_uniform("u_renpy_matrixcolor", matrix)

    # Default case - no transformation matrix.
    if rxdx == 1 and rxdy == 0 and rydx == 0 and rydy == 1:
        self.reverse = IDENTITY
    else:
        self.reverse = Matrix2D(rxdx, rxdy, rydx, rydy)

    # xpos and ypos.
    if perspective:
        placement = (state.xpos, state.ypos, state.xanchor, state.yanchor, state.xoffset, state.yoffset, True)
        xplacement, yplacement = renpy.display.core.place(width, height, width, height, placement)

        self.reverse = Matrix.offset(-xplacement, -yplacement, -state.zpos) * self.reverse

        if rotate is not None:
            m = Matrix.offset(-width / 2, -height / 2, 0.0)
            m = Matrix.rotate(0, 0, -rotate) * m
            m = Matrix.offset(width / 2, height / 2, 0.0) * m

            self.reverse = m * self.reverse

    elif state.zpos:
        self.reverse = Matrix.offset(0, 0, state.zpos) * self.reverse

    # matrixtransform
    if state.matrixtransform is not None:

        if state.matrixanchor is None:

            manchorx = width / 2.0
            manchory = height / 2.0

        else:
            manchorx, manchory = state.matrixanchor

            if type(manchorx) is float:
                manchorx *= width
            if type(manchory) is float:
                manchory *= height

        m = Matrix.offset(-manchorx, -manchory, 0.0)
        m = state.matrixtransform * m
        m = Matrix.offset(manchorx, manchory, 0.0) * m

        self.reverse = m * self.reverse

    if state.zzoom and z11:
        zzoom = (z11 - state.zpos) / z11

        m = Matrix.offset(-width / 2, -height / 2, 0.0)
        m = Matrix.scale(zzoom, zzoom, 1) * m
        m = Matrix.offset(width / 2, height / 2, 0.0) * m

        self.reverse = m * self.reverse

    # perspective
    if perspective:
        near, z11, far = perspective
        self.reverse = Matrix.perspective(width, height, near, z11, far) * self.reverse

    # Set the forward matrix.
    if self.reverse is not IDENTITY:
        rv.reverse = self.reverse
        self.forward = rv.forward = self.reverse.inverse()
    else:
        self.forward = IDENTITY

    pos = (xo, yo)

    if state.subpixel:
        rv.subpixel_blit(cr, pos)
    else:
        rv.blit(cr, pos)

    if mesh and perspective:
        mr = rv = make_mesh(rv)

    # Nearest neighbor.
    rv.nearest = state.nearest

    if state.nearest:
        rv.add_property("texture_scaling", "nearest")

    if state.blend:
        rv.add_property("blend_func", renpy.config.gl_blend_func[state.blend])

    # Alpha.
    alpha = state.alpha

    if alpha < 0.0:
        alpha = 0.0
    elif alpha > 1.0:
        alpha = 1.0

    rv.alpha = alpha
    rv.over = 1.0 - state.additive

    if (rv.alpha != 1.0) or (rv.over != 1.0):
        rv.add_shader("renpy.alpha")
        rv.add_uniform("u_renpy_alpha", rv.alpha)
        rv.add_uniform("u_renpy_over", rv.over)

    # Shaders and uniforms.
    if state.shader is not None:

        if isinstance(state.shader, basestring):
            rv.add_shader(state.shader)
        else:
            for name in state.shader:
                rv.add_shader(name)

    for name in renpy.display.transform.uniforms:
        value = getattr(state, name, None)

        if value is not None:
            rv.add_uniform(name, value)

    for name in renpy.display.transform.gl_properties:
        value = getattr(state, name, None)

        if value is not None:
            if mesh:
                mr.add_property(name[3:], value)
            else:
                rv.add_property(name[3:], value)

    # Clipping.
    rv.xclipping = clipping
    rv.yclipping = clipping

    self.offsets = [ pos ]
    self.render_size = (width, height)

    return rv
