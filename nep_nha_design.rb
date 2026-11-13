# frozen_string_literal: true

require 'sketchup.rb'
require 'extensions.rb'

module NepNhaDesign
  unless file_loaded?(__FILE__)
    extension = SketchupExtension.new('Nếp Nhà Design – Trợ lý AI', 'nep_nha_design/main')
    extension.description = 'Chat với trợ lý AI ngay trong SketchUp và điều khiển mô hình qua công cụ tham số.'
    extension.version = '1.7.0'
    extension.creator = 'Nếp Nhà Design'
    Sketchup.register_extension(extension, true)
    file_loaded(__FILE__)
  end
end
