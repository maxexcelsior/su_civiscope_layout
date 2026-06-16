# encoding: UTF-8
module CiviscopeLayout
  module Core

    # 地块编号显示（使用 entities.add_text 创建屏幕文字实体）
    # 标签始终创建在与 site 相同的容器内（BP 组内或模型顶层）
    # 所有标签统一存放在 "TX-地块编号" 图层（标记）

    unless defined?(LABEL_LAYER_NAME)
      LABEL_LAYER_NAME = "TX-地块编号".freeze
    end
    unless defined?(LABEL_ATTR_KEY)
      LABEL_ATTR_KEY = "civiscope_site_number_label".freeze
    end

    def self.ensure_site_number_overlay(model)
      cleanup_orphaned_labels(model)
    end

    def self.cleanup_orphaned_labels(model)
      scan_for_labels(model.entities).each do |t|
        t.erase! if t.get_attribute("dynamic_attributes", LABEL_ATTR_KEY)
      end
    rescue => e
      # 静默处理
    end

    # 快速扫描：顶层 + 一层组/组件深度
    def self.scan_for_labels(entities)
      result = entities.grep(Sketchup::Text)
      entities.grep(Sketchup::Group).each do |g|
        result.concat(g.entities.grep(Sketchup::Text))
      end
      entities.grep(Sketchup::ComponentInstance).each do |c|
        result.concat(c.definition.entities.grep(Sketchup::Text))
      end
      result
    end

    def self.toggle_site_number(id_str)
      model = Sketchup.active_model
      site = model.find_entity_by_persistent_id(id_str.to_i)
      site ||= model.entities.to_a.find { |e| self.get_short_id(e) == id_str }
      return unless site

      @site_number_labels ||= {}

      if @site_number_labels.key?(id_str)
        remove_site_number_label(id_str)
      else
        remove_orphaned_label_for(id_str)

        center = compute_site_center(site)
        return unless center

        number = site.get_attribute("dynamic_attributes", "site_no") || ""
        return if number.empty?

        create_site_number_label(id_str, center, number, site)
      end

      model.active_view.refresh
      self.refresh_stats_ui(model.selection)
    end

    def self.cancel_all_site_numbers
      return unless @site_number_labels
      @site_number_labels.keys.each { |id_str| remove_site_number_label(id_str) }
      @site_number_labels = {}
      Sketchup.active_model.active_view.refresh
    end

    def self.get_or_create_label_layer(model)
      layer = model.layers[LABEL_LAYER_NAME]
      unless layer
        layer = model.layers.add(LABEL_LAYER_NAME)
      end
      layer
    end

    # 创建浮动文字标签
    # center 参数已经是父容器局部坐标（来自 compute_site_center）
    def self.create_site_number_label(id_str, center, number, site = nil)
      model = Sketchup.active_model

      settings = get_overlay_number_settings
      if settings["use_height_limit"] && site
        height_limit = site.get_attribute("dynamic_attributes", "height_limit").to_f
        offset = settings["height_offset"].to_f
        height_m = height_limit > 0 ? height_limit + offset : (settings["height"] || 2.0).to_f
      elsif settings["use_fixed_height"]
        height_m = (settings["height"] || 2.0).to_f
      else
        height_m = 2.0
      end

      # 标签创建在与 site 相同的容器内
      if site
        parent = site.parent
        if parent.is_a?(Sketchup::Entities)
          target_entities = parent
        elsif parent.respond_to?(:entities)
          target_entities = parent.entities  # ComponentDefinition 等情况
        else
          target_entities = model.entities
        end
      else
        target_entities = model.entities
      end
      pt = center.offset([0, 0, height_m / 0.0254])
      layer = get_or_create_label_layer(model)

      # 不能放在 start_operation/commit_operation 包裹下，否则实体立即变为 Deleted Entity
      text_ent = target_entities.add_text(number, pt)
      text_ent.layer = layer
      text_ent.set_attribute("dynamic_attributes", LABEL_ATTR_KEY, id_str)

      @site_number_labels ||= {}
      @site_number_labels[id_str] = text_ent
    end

    def self.remove_site_number_label(id_str)
      text_ent = @site_number_labels&.delete(id_str)
      return unless text_ent && text_ent.valid?

      begin
        text_ent.erase!
      rescue => e
        puts "[Civiscope] Failed to remove site label: #{e.message}"
      end
    end

    # 删除某个地块的孤立标签
    def self.remove_orphaned_label_for(id_str)
      model = Sketchup.active_model
      scan_for_labels(model.entities).each do |t|
        if t.get_attribute("dynamic_attributes", LABEL_ATTR_KEY) == id_str
          t.erase!
          return
        end
      end
    rescue => e
      # 静默处理
    end

    def self.site_number_visible?(id_str)
      @site_number_labels&.key?(id_str) || false
    end

    # 计算地块边界的中心点（父容器局部坐标）
    # 返回的坐标可直接用于 site.parent.entities.add_text
    def self.compute_site_center(site)
      definition = site.is_a?(Sketchup::Group) ? site.definition : (site.respond_to?(:definition) ? site.definition : nil)
      return nil unless definition

      local_pts = nil

      boundary_group = definition.entities.grep(Sketchup::Group).find do |g|
        g.get_attribute("dynamic_attributes", "site_boundary") == "true"
      end

      if boundary_group
        edges = boundary_group.entities.grep(Sketchup::Edge)
        if edges.any?
          tr_boundary = boundary_group.transformation
          local_pts = edges.map do |e|
            s = e.start.position.transform(tr_boundary)
            e_pt = e.end.position.transform(tr_boundary)
            [s, e_pt]
          end.flatten.uniq { |p| [p.x.round(6), p.y.round(6), p.z.round(6)] }
        end
      end

      unless local_pts
        horizontal_faces = definition.entities.grep(Sketchup::Face).select { |f| f.normal.z.abs > 0.99 }
        if horizontal_faces.any?
          local_pts = horizontal_faces.flat_map { |f| f.outer_loop.vertices.map(&:position) }.uniq { |p| [p.x.round(6), p.y.round(6), p.z.round(6)] }
        else
          b = definition.bounds
          local_pts = [b.corner(0), b.corner(1), b.corner(3), b.corner(2)]
        end
      end

      return nil if local_pts.empty?

      cx = local_pts.map(&:x).sum / local_pts.length.to_f
      cy = local_pts.map(&:y).sum / local_pts.length.to_f
      cz = local_pts.map(&:z).sum / local_pts.length.to_f
      local_center = Geom::Point3d.new(cx, cy, cz)

      # 从 definition 局部空间转换到父容器空间（通过 site 自身的变换）
      local_center.transform(site.transformation)
    end

    # ==========================================
    # 建筑编号显示
    # ==========================================

    unless defined?(BLDG_LABEL_LAYER_NAME)
      BLDG_LABEL_LAYER_NAME = "TX-建筑编号".freeze
    end
    unless defined?(BLDG_LABEL_ATTR_KEY)
      BLDG_LABEL_ATTR_KEY = "civiscope_bldg_number_label".freeze
    end

    def self.ensure_bldg_number_overlay(model)
      cleanup_orphaned_bldg_labels(model)
    end

    def self.cleanup_orphaned_bldg_labels(model)
      scan_for_labels(model.entities).each do |t|
        t.erase! if t.get_attribute("dynamic_attributes", BLDG_LABEL_ATTR_KEY)
      end
    rescue => e
    end

    def self.toggle_bldg_number(id_str)
      model = Sketchup.active_model
      bldg = model.find_entity_by_persistent_id(id_str.to_i)
      bldg ||= model.entities.to_a.find { |e| self.get_short_id(e) == id_str }
      return unless bldg

      @bldg_number_labels ||= {}

      if @bldg_number_labels.key?(id_str)
        remove_bldg_number_label(id_str)
      else
        remove_orphaned_bldg_label_for(id_str)

        center = compute_bldg_center_at_base(bldg)
        return unless center

        number = bldg.get_attribute("dynamic_attributes", "bldg_no") || ""
        return if number.empty?

        create_bldg_number_label(id_str, center, number, bldg)
      end

      model.active_view.refresh
      self.refresh_stats_ui(model.selection)
    end

    def self.cancel_all_bldg_numbers
      return unless @bldg_number_labels
      @bldg_number_labels.keys.each { |id_str| remove_bldg_number_label(id_str) }
      @bldg_number_labels = {}
      Sketchup.active_model.active_view.refresh
    end

    def self.get_or_create_bldg_label_layer(model)
      layer = model.layers[BLDG_LABEL_LAYER_NAME]
      unless layer
        layer = model.layers.add(BLDG_LABEL_LAYER_NAME)
      end
      layer
    end

    # 计算建筑标签高度（米）
    # 裙楼：使用总高度（裙楼高度）+ 偏移
    # 塔楼/独立：使用建筑真高（有效高度）+ 偏移
    def self.compute_bldg_label_height(building)
      bldg_type = building.get_attribute("dynamic_attributes", "bldg_type") || "塔楼"
      settings = get_overlay_bldg_settings
      offset = settings["offset"].to_f

      own_th = building.get_attribute("dynamic_attributes", "total_height").to_f

      if bldg_type == "裙楼"
        height_m = own_th
      else  # 塔楼 or 独立
        height_m = self.compute_effective_h(building, bldg_type, own_th)
      end

      height_m = height_m > 0 ? height_m : 10.0
      height_m + offset
    end

    # 计算建筑底部中心点（父容器局部坐标）
    # compute_site_center 对体块会返回中部高度（顶部+底部面的平均z）
    # 此处修正为建筑基底 z，确保标签从建筑根部向上偏移
    def self.compute_bldg_center_at_base(building)
      center = compute_site_center(building)
      return nil unless center

      definition = building.is_a?(Sketchup::Group) ? building.definition : (building.respond_to?(:definition) ? building.definition : nil)
      return center unless definition

      bounds = definition.bounds
      base_pt = Geom::Point3d.new(0, 0, bounds.min.z).transform(building.transformation)
      Geom::Point3d.new(center.x, center.y, base_pt.z)
    end

    def self.create_bldg_number_label(id_str, center, number, building)
      model = Sketchup.active_model
      height_m = self.compute_bldg_label_height(building)

      # 标签创建在与 building 相同的容器内
      if building
        parent = building.parent
        if parent.is_a?(Sketchup::Entities)
          target_entities = parent
        elsif parent.respond_to?(:entities)
          target_entities = parent.entities
        else
          target_entities = model.entities
        end
      else
        target_entities = model.entities
      end

      pt = center.offset([0, 0, height_m / 0.0254])
      layer = get_or_create_bldg_label_layer(model)

      text_ent = target_entities.add_text(number, pt)
      text_ent.layer = layer
      text_ent.set_attribute("dynamic_attributes", BLDG_LABEL_ATTR_KEY, id_str)

      @bldg_number_labels ||= {}
      @bldg_number_labels[id_str] = text_ent
    end

    def self.remove_bldg_number_label(id_str)
      text_ent = @bldg_number_labels&.delete(id_str)
      return unless text_ent && text_ent.valid?

      begin
        text_ent.erase!
      rescue => e
        puts "[Civiscope] Failed to remove bldg label: #{e.message}"
      end
    end

    def self.remove_orphaned_bldg_label_for(id_str)
      model = Sketchup.active_model
      scan_for_labels(model.entities).each do |t|
        if t.get_attribute("dynamic_attributes", BLDG_LABEL_ATTR_KEY) == id_str
          t.erase!
          return
        end
      end
    rescue => e
    end

    def self.bldg_number_visible?(id_str)
      @bldg_number_labels&.key?(id_str) || false
    end

  end
end
