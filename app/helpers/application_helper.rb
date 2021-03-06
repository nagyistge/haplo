# Haplo Platform                                     http://haplo.org
# (c) Haplo Services Ltd 2006 - 2016    http://www.haplo-services.com
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.


# More general helper methods in app/helpers/application/*_helper.rb
# Loaded by ApplicationController

module ApplicationHelper
  include KConstants

  # ========================================================================================================
  # Misc bits and pieces
  def possessive_case_of(name)
    (name =~ /[sS]\z/) ? "#{name}'" : "#{name}'s"
  end

  # ========================================================================================================
  # Data attributes in body tag
  def body_tag_data_attributes
    attrs = ''
    if @represented_objref
      attrs << %Q! data-ref="#{@represented_objref.to_presentation}"!
    end
    if params.has_key?(:_sx)
      attrs << ' data-sp="1"'
    end
    attrs
  end

  # ========================================================================================================
  # Web fonts
  def webfonts_enabled?
    return false if (KApp.global(:appearance_webfont_size) || 0) == 0
    return false if request.user_agent =~ /MSIE [67]\./ # Doesn't seem worth trying on these browsers.
    true
  end

end
