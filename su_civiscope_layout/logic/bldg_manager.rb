# 编码：UTF-8
module CiviscopeLayout
  module Core
    
    def self.do_convert_bldg
      model = Sketchup.active_model
      return if model.selection.empty?
      
      model.start_operation('转换为CIM建筑', true)
      target_layer = self.ensure_layer("CIM-mass")
      
      new_selection = []
      
      model.selection.to_a.each do |t|
        next unless t.respond_to?(:manifold?) && t.manifold?
        inst = t.is_a?(Sketchup::Group) ? t.to_component : t
        inst.layer = target_layer 
        
        inst.set_attribute("dynamic_attributes", "_formatversion", 1.0)
        inst.set_attribute("dynamic_attributes", "floor_height", "3.0")
        inst.set_attribute("dynamic_attributes", "bldg_func", DEFAULT_BLDG_FUNCS[0])
        inst.set_attribute("dynamic_attributes", "bldg_type", "塔楼")
        inst.set_attribute("dynamic_attributes", "bldg_no", "") 
        
        self.attach_observers(inst)
        self.auto_recalculate(inst, true)
        new_selection << inst
      end
      
      model.selection.clear
      model.selection.add(new_selection) unless new_selection.empty?
      self.refresh_stats_ui(model.selection)
      model.commit_operation
    end

    def self.do_apply_bldg(h, f, no, type = nil, th = nil)
      puts "[DEBUG-FL] do_apply_bldg ENTER h=#{h} f=#{f} th=#{th} type=#{type}"
      @pending_recalc_entity = nil
      model = Sketchup.active_model
      model.start_operation('修改建筑属性', true)
      model.selection.to_a.each do |inst|
        eid = get_short_id(inst) rescue '?'
        next unless inst.get_attribute("dynamic_attributes", "bldg_func")
        puts "[DEBUG-FL] do_apply_bldg processing entity=#{eid}"

        req_th = th.to_f

        if req_th > 0
          # 恢复建筑至完整高度，以实际几何高度为基准缩放
          old_roof_sh = inst.get_attribute("dynamic_attributes", "roof_structure_height").to_f
          if old_roof_sh > 0
            CiviscopeLayout::Core.skip_recalc = true
            begin
              self.remove_roof_structure(inst)
              self.push_top_face(inst, old_roof_sh)
              inst.set_attribute("dynamic_attributes", "roof_structure_height", "0")
            ensure
              CiviscopeLayout::Core.skip_recalc = false
            end
          end

          actual_th_m = ((inst.bounds.max.z - inst.bounds.min.z) * 0.0254).round(4)
          if actual_th_m > 0 && (actual_th_m - req_th).abs > 0.01
            if inst.is_a?(Sketchup::ComponentInstance) && inst.make_unique
              ObserverManager.attach_entity_observers(inst)
            end
            scale_z = req_th / actual_th_m
            bnd = inst.bounds
            base_pt = Geom::Point3d.new(bnd.center.x, bnd.center.y, bnd.min.z)
            tr = Geom::Transformation.scaling(base_pt, 1.0, 1.0, scale_z)
            inst.transform!(tr)
          end
        end

        inst.set_attribute("dynamic_attributes", "floor_height", h.to_s)
        inst.set_attribute("dynamic_attributes", "bldg_func", f.to_s)
        inst.set_attribute("dynamic_attributes", "bldg_no", no.to_s)
        inst.set_attribute("dynamic_attributes", "bldg_type", type.to_s) if type
        self.auto_recalculate(inst, true, true)
      end
      self.refresh_stats_ui(model.selection)
      model.commit_operation
    end

    # 获取实体顶部/底部世界坐标 Z 值
    def self.get_world_z(entity, which)
      definition = entity.is_a?(Sketchup::Group) ? entity.definition : entity.definition
      return nil unless definition
      bounds = definition.bounds
      tr = self.get_full_world_transform(entity) rescue entity.transformation
      local_z = (which == :bottom) ? bounds.min.z : bounds.max.z
      local_pt = Geom::Point3d.new(bounds.center.x, bounds.center.y, local_z)
      world_pt = local_pt.transform(tr)
      world_pt.z * 0.0254
    end

    # 返回与 entity 同层级的所有 CIM 建筑实体
    def self.find_sibling_buildings(entity)
      siblings = []
      parent_ents = entity.parent.entities rescue nil
      return siblings unless parent_ents
      parent_ents.each do |e|
        next unless e.is_a?(Sketchup::Group) || e.is_a?(Sketchup::ComponentInstance)
        siblings << e if e.get_attribute("dynamic_attributes", "bldg_func")
      end
      siblings
    end

    # 获取实体在世界坐标系中的 XY 包围盒 [min_x, max_x, min_y, max_y]
    def self.get_world_xy_bounds(entity)
      tr = self.get_full_world_transform(entity) rescue entity.transformation
      bnd = entity.definition.bounds
      corners = [
        Geom::Point3d.new(bnd.min.x, bnd.min.y, 0),
        Geom::Point3d.new(bnd.max.x, bnd.min.y, 0),
        Geom::Point3d.new(bnd.min.x, bnd.max.y, 0),
        Geom::Point3d.new(bnd.max.x, bnd.max.y, 0),
      ]
      world_corners = corners.map { |c| c.transform(tr) }
      xs = world_corners.map(&:x)
      ys = world_corners.map(&:y)
      [xs.min, xs.max, ys.min, ys.max]
    end

    # 两个 XY 包围盒是否重叠（含容差）
    def self.xy_bounds_overlap?(bb1, bb2)
      tolerance = 0.1  # 10cm 容差，处理浮点精度
      !(bb1[1] + tolerance < bb2[0] || bb2[1] + tolerance < bb1[0] ||
        bb1[3] + tolerance < bb2[2] || bb2[3] + tolerance < bb1[2])
    end

    # 递归查找塔楼下方所有裙楼，返回裙楼高度数组
    def self.find_podiums_under_tower(entity, visited = [])
      return [] if visited.include?(entity)
      visited << entity
      podium_heights = []

      entity_world_bottom = self.get_world_z(entity, :bottom)
      eid = get_short_id(entity) rescue '?'
      puts "[DEBUG-PODIUM] find_podiums_under_tower entity=#{eid} world_bottom_z=#{entity_world_bottom&.round(4)}"
      return [] if entity_world_bottom.nil?

      entity_bb = self.get_world_xy_bounds(entity)
      puts "[DEBUG-PODIUM] entity_bb=[#{entity_bb.map { |v| v.round(4) }.join(', ')}]"

      self.find_sibling_buildings(entity).each do |sibling|
        next if visited.include?(sibling)
        bldg_type = sibling.get_attribute("dynamic_attributes", "bldg_type") || ""
        next unless bldg_type == "裙楼"  # "裙楼"

        sid = get_short_id(sibling) rescue '?'
        sibling_world_top = self.get_world_z(sibling, :top)
        puts "[DEBUG-PODIUM]   checking podium=#{sid} world_top_z=#{sibling_world_top&.round(4)}"
        next if sibling_world_top.nil?

        vert_diff = (entity_world_bottom - sibling_world_top).abs
        puts "[DEBUG-PODIUM]     vert_diff=#{vert_diff.round(4)} (need <1.0)"

        # 垂直匹配：entity 底部 ≈ 裙楼顶部（容差 1m）
        if vert_diff >= 1.0
          puts "[DEBUG-PODIUM]     VERTICAL MISMATCH — skipping"
          next
        end

        # 水平匹配：塔楼/裙楼的 XY 中心点必须落在裙楼 XY 包围盒内
        # （比 overlap 更严格，避免相邻裙楼之间的误匹配）
        sibling_bb = self.get_world_xy_bounds(sibling)
        entity_center_x = (entity_bb[0] + entity_bb[1]) / 2.0
        entity_center_y = (entity_bb[2] + entity_bb[3]) / 2.0
        center_in = entity_center_x >= sibling_bb[0] && entity_center_x <= sibling_bb[1] &&
                    entity_center_y >= sibling_bb[2] && entity_center_y <= sibling_bb[3]
        puts "[DEBUG-PODIUM]     sibling_bb=[#{sibling_bb.map { |v| v.round(4) }.join(', ')}] center=(#{entity_center_x.round(2)}, #{entity_center_y.round(2)}) center_in=#{center_in}"

        unless center_in
          puts "[DEBUG-PODIUM]     XY MISMATCH — center not inside podium"
          next
        end

        podium_th = sibling.get_attribute("dynamic_attributes", "total_height").to_f
        puts "[DEBUG-PODIUM]     MATCH! adding podium_th=#{podium_th}"
        podium_heights << podium_th
        podium_heights.concat(self.find_podiums_under_tower(sibling, visited))
      end
      puts "[DEBUG-PODIUM] result podium_heights=#{podium_heights.inspect} sum=#{podium_heights.sum}"
      podium_heights
    end

    # 获取用于折减系数查询的高度（塔楼用真高，裙楼/独立用自身高度）
    def self.get_height_for_reduction(entity)
      bldg_type = entity.get_attribute("dynamic_attributes", "bldg_type") || "塔楼"
      bounds = entity.bounds
      own_th = ((bounds.max.z - bounds.min.z) * 0.0254).round(2)
      case bldg_type
      when '塔楼'
        compute_effective_h(entity, bldg_type, own_th)
      else
        own_th
      end
    end

    # 计算有效总高度 H
    def self.compute_effective_h(entity, bldg_type, own_th)
      case bldg_type
      when "独立"  # "独立"
        own_th
      when "塔楼"  # "塔楼"
        podium_heights = self.find_podiums_under_tower(entity)
        own_th + podium_heights.sum
      else
        own_th
      end
    end

    # 屋顶构筑物高度
    def self.compute_roof_structure_height(h)
      if h <= 100
        0.0
      elsif h <= 150
        10.0
      elsif h <= 200
        15.0
      elsif h <= 250
        20.0
      elsif h <= 300
        25.0
      else
        40.0
      end
    end

    # 避难层层数
    def self.compute_refuge_floors(h)
      h > 100 ? (h / 50.0).ceil - 1 : 0
    end

    # 推拉建筑顶面（正值=向上恢复，负值=向下切除）
    def self.push_top_face(entity, delta_m)
      return if delta_m.abs < 0.0001
      definition = entity.is_a?(Sketchup::Group) ? entity.definition : entity.definition
      return unless definition
      ents = definition.entities
      top_faces = ents.grep(Sketchup::Face).select { |f| f.normal.z > 0.99 }
      return if top_faces.empty?
      max_z = top_faces.map { |f| f.bounds.max.z }.max
      top_face = top_faces.find { |f| (f.bounds.max.z - max_z).abs < 0.001 }
      return unless top_face
      local_scale_z = entity.transformation.zscale
      delta_inch = (delta_m / 0.0254) / local_scale_z
      top_face.pushpull(delta_inch)
    end

    def self.remove_roof_structure(entity)
      model = Sketchup.active_model

      roof_id_str = entity.get_attribute("civiscope", "roof_structure_id")
      if roof_id_str
        roof = model.find_entity_by_persistent_id(roof_id_str.to_i) rescue nil
        if roof && roof.valid?
          roof.erase!
          entity.set_attribute("civiscope", "roof_structure_id", nil)
          return true
        end
      end

      # 回退：扫描 definition 内部（屋顶构筑物嵌套在建筑 definition 中）
      definition = entity.is_a?(Sketchup::Group) ? entity.definition : entity.definition
      if definition
        old = definition.entities.grep(Sketchup::Group).select { |g|
          g.get_attribute("civiscope", "is_roof_structure")
        }
        if old.any?
          definition.entities.erase_entities(old)
          entity.set_attribute("civiscope", "roof_structure_id", nil)
          return true
        end
      end
      false
    end

    # 计算短边的 ratio 比例（用于屋顶构筑物偏移距离）
    def self.compute_short_edge_ratio(vertices, ratio)
      return 0 if vertices.length < 3
      xs = vertices.map(&:x)
      ys = vertices.map(&:y)
      short_edge = [xs.max - xs.min, ys.max - ys.min].min
      short_edge * ratio
    end

    # 将多边形顶点向内偏移（XY 平面，朝质心方向）
    def self.offset_polygon_vertices(vertices, distance)
      return nil if vertices.length < 3
      z = vertices.first.z
      cx = vertices.map(&:x).sum / vertices.length.to_f
      cy = vertices.map(&:y).sum / vertices.length.to_f
      result = vertices.map do |v|
        dx = v.x - cx
        dy = v.y - cy
        dist = Math.sqrt(dx*dx + dy*dy)
        if dist < 0.001
          Geom::Point3d.new(cx, cy, z)
        else
          scale = (dist - distance) / dist
          Geom::Point3d.new(cx + dx * scale, cy + dy * scale, z)
        end
      end
      result.uniq { |v| [v.x.round(6), v.y.round(6), v.z.round(6)] }
    end

    # 创建屋顶构筑物3D几何（仅塔楼和独立建筑）
    # 在建筑 definition 内部创建，向内偏移固定10m后向上挤出
    def self.create_roof_structure(entity, roof_structure_height_m)
      self.remove_roof_structure(entity)
      return if roof_structure_height_m <= 0

      definition = entity.is_a?(Sketchup::Group) ? entity.definition : entity.definition
      ents = definition.entities
      return unless ents

      top_faces = ents.grep(Sketchup::Face).select { |f| f.normal.z > 0.99 }
      return if top_faces.empty?

      max_z = top_faces.map { |f| f.bounds.max.z }.max
      top_face = top_faces.find { |f| (f.bounds.max.z - max_z).abs < 0.001 }
      return unless top_face

      local_scale_z = entity.transformation.zscale
      roof_sh_inch = (roof_structure_height_m / 0.0254) / local_scale_z
      offset_inch = (10.0 / 0.0254) / local_scale_z  # 固定 10m

      top_verts = top_face.outer_loop.vertices.map(&:position)
      inner_verts = offset_polygon_vertices(top_verts, offset_inch)
      return if inner_verts.nil? || inner_verts.length < 3

      roof_group = ents.add_group
      roof_group.name = "屋顶构筑物"
      roof_group.set_attribute("civiscope", "is_roof_structure", true)
      entity.set_attribute("civiscope", "roof_structure_id", roof_group.persistent_id.to_s)

      inner_face = roof_group.entities.add_face(inner_verts)
      return unless inner_face
      inner_face.reverse! if inner_face.normal.z < 0
      inner_face.pushpull(roof_sh_inch)
    end

    def self.calc_bldg_data(entity, skip_operation = false)
      eid = get_short_id(entity) rescue '?'
      puts "[DEBUG-FL] calc_bldg_data ENTER entity=#{eid} skip_operation=#{skip_operation} skip_recalc=#{CiviscopeLayout::Core.skip_recalc}"
      @pending_recalc_entity = nil
      UI.stop_timer(@skip_recalc_restore_timer_id) if @skip_recalc_restore_timer_id
      CiviscopeLayout::Core.skip_recalc = true

      # 确保定义独立，避免复制体之间相互影响
      made_unique = false
      if entity.is_a?(Sketchup::ComponentInstance) && entity.make_unique
        ObserverManager.attach_entity_observers(entity)
        made_unique = true
      end
      puts "[DEBUG-FL] calc_bldg_data is_component=#{entity.is_a?(Sketchup::ComponentInstance)} made_unique=#{made_unique}"

      model = Sketchup.active_model
      model.start_operation('更新体块数据', true, true, true) unless skip_operation

      begin
        # 恢复建筑至完整高度，移除旧屋顶构筑物，确保为干净的 manifold solid
        old_roof_sh = entity.get_attribute("dynamic_attributes", "roof_structure_height").to_f
        had_roof = old_roof_sh > 0
        puts "[DEBUG-FL] calc_bldg_data had_roof=#{had_roof} old_roof_sh=#{old_roof_sh}"
        if had_roof
          self.remove_roof_structure(entity)
          self.push_top_face(entity, old_roof_sh)
        end

        is_manifold = entity.manifold?
        puts "[DEBUG-FL] calc_bldg_data manifold=#{is_manifold}"
        # 注意：不在此处 return——分层线 group 会破坏 manifold 检查，
        # 若直接 return 则永远无法清理旧分层线。后续 push_top_face 和
        # create_roof_structure 在找不到顶面时会安全跳过，不会崩溃。
        fh = entity.get_attribute("dynamic_attributes", "floor_height").to_f
        puts "[DEBUG-FL] calc_bldg_data fh=#{fh}"
        return if fh <= 0

        bldg_type = entity.get_attribute("dynamic_attributes", "bldg_type") || "塔楼"

        # 建筑已恢复完整高度，bounds 反映真实总高
        bounds = entity.bounds
        th_m = ((bounds.max.z - bounds.min.z) * 0.0254).round(2)

        h_effective = self.compute_effective_h(entity, bldg_type, th_m)
        roof_sh = self.compute_roof_structure_height(h_effective)
        refuge_fl = self.compute_refuge_floors(h_effective)

        has_roof = (bldg_type == "塔楼" || bldg_type == "独立") && roof_sh > 0

        physical_floors = th_m > roof_sh ? ((th_m - roof_sh) / fh).floor : 0
        fc = physical_floors - refuge_fl
        fc = 0 if fc < 0

        # 使用底面面积（比体积/高度更精确）
        # 注意：definition 内的面面积为局部坐标，需乘以 XY 缩放因子
        definition = entity.is_a?(Sketchup::Group) ? entity.definition : entity.definition
        bottom_faces = definition.entities.grep(Sketchup::Face).select { |f| f.normal.z < -0.99 }
        if bottom_faces.any?
          min_z = bottom_faces.map { |f| f.bounds.min.z }.min
          b_area_sq_inch = bottom_faces.select { |f| (f.bounds.min.z - min_z).abs < 0.001 }.sum(&:area)
          tr = entity.transformation
          b_area = (b_area_sq_inch * tr.xscale * tr.yscale * (0.0254 ** 2)).round(2)
        else
          vol_m3 = entity.volume * (0.0254 ** 3)
          b_area = th_m > 0 ? (vol_m3 / th_m).round(2) : 0
        end
        t_area = (fc * b_area).round(2)

        need_update = (entity.get_attribute("dynamic_attributes", "bldg_area") != t_area.to_s) ||
                      (entity.get_attribute("dynamic_attributes", "floor_count") != fc.to_s) ||
                      (entity.get_attribute("dynamic_attributes", "base_area") != b_area.to_s) ||
                      (entity.get_attribute("dynamic_attributes", "total_height") != th_m.to_s) ||
                      (entity.get_attribute("dynamic_attributes", "roof_structure_height") != roof_sh.to_s) ||
                      (entity.get_attribute("dynamic_attributes", "refuge_floors") != refuge_fl.to_s)

        puts "[DEBUG-FL] calc_bldg_data th_m=#{th_m} fh=#{fh} fc=#{fc} b_area=#{b_area} t_area=#{t_area} roof_sh=#{roof_sh} physical_floors=#{physical_floors} need_update=#{need_update}"
        puts "[DEBUG-FL] calc_bldg_data stored: total_h=#{entity.get_attribute("dynamic_attributes", "total_height")} fc=#{entity.get_attribute("dynamic_attributes", "floor_count")} b_area=#{entity.get_attribute("dynamic_attributes", "base_area")} bldg_area=#{entity.get_attribute("dynamic_attributes", "bldg_area")} roof_sh=#{entity.get_attribute("dynamic_attributes", "roof_structure_height")}"

        if need_update
          if has_roof
            self.push_top_face(entity, -roof_sh)
            fl_roof_sh = 0
          else
            fl_roof_sh = roof_sh
          end

          entity.set_attribute("dynamic_attributes", "total_height", th_m.to_s)
          entity.set_attribute("dynamic_attributes", "floor_count", fc.to_s)
          entity.set_attribute("dynamic_attributes", "base_area", b_area.to_s)
          entity.set_attribute("dynamic_attributes", "bldg_area", t_area.to_s)
          entity.set_attribute("dynamic_attributes", "roof_structure_height", roof_sh.to_s)
          entity.set_attribute("dynamic_attributes", "refuge_floors", refuge_fl.to_s)

          puts "[DEBUG-FL] calc_bldg_data → calling update_floor_lines(physical_floors=#{physical_floors}, fh=#{fh}, fl_roof_sh=#{fl_roof_sh})"
          self.update_floor_lines(entity, physical_floors, fh, fl_roof_sh)

          if has_roof
            self.create_roof_structure(entity, roof_sh)
          end
        else
          puts "[DEBUG-FL] calc_bldg_data need_update=FALSE — skipping floor_lines update"
          # 无需更新，恢复原有切除状态
          if had_roof
            self.push_top_face(entity, -old_roof_sh)
            self.create_roof_structure(entity, old_roof_sh)
          end
        end
      ensure
        model.commit_operation unless skip_operation
        @skip_recalc_restore_timer_id = UI.start_timer(0.25, false) do
          @skip_recalc_restore_timer_id = nil
          CiviscopeLayout::Core.skip_recalc = false
        end
      end
    end

    def self.update_floor_lines(entity, floor_count, floor_height_m, roof_structure_height_m = 0)
      eid = get_short_id(entity) rescue '?'
      puts "[DEBUG-FL] update_floor_lines ENTER entity=#{eid} floor_count=#{floor_count} floor_height_m=#{floor_height_m} roof_sh_m=#{roof_structure_height_m}"

      # 确保定义独立，避免复制体之间相互影响
      if entity.is_a?(Sketchup::ComponentInstance) && entity.make_unique
        ObserverManager.attach_entity_observers(entity)
        puts "[DEBUG-FL] update_floor_lines made_unique=true"
      end

      ents = (entity.is_a?(Sketchup::ComponentInstance) || entity.is_a?(Sketchup::Group)) ? entity.definition.entities : nil
      unless ents
        puts "[DEBUG-FL] update_floor_lines RETURN: no entities collection"
        return
      end

      # Dump all groups in definition before cleanup
      all_groups_before = ents.grep(Sketchup::Group)
      puts "[DEBUG-FL] update_floor_lines total groups in def=#{all_groups_before.size}: #{all_groups_before.map { |g| "name='#{g.name}' attr=#{g.get_attribute('civiscope', 'is_floor_lines_group').inspect} valid=#{g.valid?}" }.join(' | ')}"

      # Clear old floor lines (both legacy edges and new group style)
      old_edges = ents.grep(Sketchup::Edge).select { |e| e.get_attribute("civiscope", "is_floor_line") }
      puts "[DEBUG-FL] update_floor_lines old_edges=#{old_edges.size}"
      ents.erase_entities(old_edges) if old_edges.any?

      old_groups = ents.grep(Sketchup::Group).select { |g|
        g.get_attribute("civiscope", "is_floor_lines_group") || g.name == "Floor Lines"
      }
      puts "[DEBUG-FL] update_floor_lines old_groups found=#{old_groups.size}: #{old_groups.map { |g| "name='#{g.name}' valid=#{g.valid?} entities=#{g.entities.size}" }.join(' | ')}"

      old_groups.each { |g|
        puts "[DEBUG-FL] update_floor_lines erasing group name='#{g.name}' valid=#{g.valid?}"
        g.erase! if g.valid?
      }

      # Verify cleanup
      remaining = ents.grep(Sketchup::Group).select { |g|
        g.get_attribute("civiscope", "is_floor_lines_group") || g.name == "Floor Lines"
      }
      puts "[DEBUG-FL] update_floor_lines after erase, remaining old groups=#{remaining.size}"

      floor_count = floor_count.to_i
      return if floor_count <= 1

      # 排除屋顶构筑物内部的边线（避免 max_z 受屋顶构筑物影响）
      roof_groups = ents.grep(Sketchup::Group).select { |g| g.get_attribute("civiscope", "is_roof_structure") }
      roof_edges = roof_groups.flat_map { |g| g.entities.grep(Sketchup::Edge) }
      building_edges = ents.grep(Sketchup::Edge) - roof_edges
      vertex_zs = building_edges.flat_map { |e| [e.start.position.z, e.end.position.z] }
      return if vertex_zs.empty?

      min_z = vertex_zs.min
      max_z = vertex_zs.max

      # Detect base edges (usually the perimeter)
      base_faces = ents.grep(Sketchup::Face).select do |f|
        f.normal.z < -0.99 && (f.bounds.min.z - min_z).abs < 0.001
      end

      if base_faces.empty?
        base_edges = ents.grep(Sketchup::Edge).select do |e|
          (e.start.position.z - min_z).abs < 0.001 && (e.end.position.z - min_z).abs < 0.001
        end
      else
        base_edges = base_faces.flat_map(&:edges).uniq
        base_edges.select! do |e|
          (e.start.position.z - min_z).abs < 0.001 && (e.end.position.z - min_z).abs < 0.001
        end
      end

      # Only keep outer edges of the building mass
      base_edges.select! do |e|
        faces = e.faces
        base_face_count = faces.count { |f| f.normal.z.abs > 0.99 && (f.bounds.min.z - min_z).abs < 0.001 }
        base_face_count < 2
      end

      return if base_edges.empty?

      # Account for local Z scale to keep lines consistent in meters
      local_scale_z = entity.transformation.zscale
      local_fh_inch = (floor_height_m / 0.0254) / local_scale_z

      # 屋顶构筑物高度不参与分层线切分
      local_roof_sh_inch = (roof_structure_height_m / 0.0254) / local_scale_z
      effective_max_z = max_z - local_roof_sh_inch

      # 将分层线放在独立 group 中，避免 add_line 分裂建筑立面破坏 solid
      floor_group = ents.add_group
      floor_group.name = "Floor Lines"
      floor_group.layer = CiviscopeLayout::Core.ensure_layer("000-分层线")
      floor_group.set_attribute("civiscope", "is_floor_lines_group", true)

      (1..floor_count).each do |i|
        z_offset = i * local_fh_inch
        cur_z = min_z + z_offset

        break if cur_z > effective_max_z

        base_edges.each do |e|
          pt1 = e.start.position
          pt2 = e.end.position
          p1 = Geom::Point3d.new(pt1.x, pt1.y, cur_z)
          p2 = Geom::Point3d.new(pt2.x, pt2.y, cur_z)

          line = floor_group.entities.add_line(p1, p2)
          line.set_attribute("civiscope", "is_floor_line", true) if line
        end
      end

    end
  end

end
