# encoding: UTF-8
module CiviscopeLayout
  module Core
    module BuildingSetback

      # 三条道路宽度区间 × 三种建筑类型的退让距离（米）
      unless defined?(RULES)
      RULES = {
        wide:   { min: 40,           # 道路红线宽度 >= 40米
          civil:      { low: 10,  mid: 15, high: 20 },
          old_city:   { low:  8,  mid: 10, high: 15 },
          industrial: { uniform: 10 }
        },
        medium: { min: 15, max: 40,  # 15米 < 道路红线宽度 < 40米
          civil:      { low:  8,  mid: 10, high: 15 },
          old_city:   { low:  5,  mid:  8, high: 13 },
          industrial: { uniform: 8 }
        },
        narrow: { max: 15,           # 道路红线宽度 <= 15米
          civil:      { low:  5,  mid:  8, high: 13 },
          old_city:   { low:  3,  mid:  5, high: 10 },
          industrial: { uniform: 5 }
        }
      }.freeze
      end

      HEIGHT_CATEGORIES = [:low, :mid, :high].freeze unless defined?(HEIGHT_CATEGORIES)
      LAYER_NAMES = ["24米以下建筑退线", "24-60米建筑退线", "60米以上建筑退线"].freeze unless defined?(LAYER_NAMES)

      INCHES_PER_METER = 0.0254 unless defined?(INCHES_PER_METER)

      # 建筑类型名称映射（用于 UI 显示）
      unless defined?(BUILDING_TYPE_NAMES)
      BUILDING_TYPE_NAMES = {
        "旧城区"            => :old_city,
        "其他地区-民用建筑"  => :civil,
        "其他地区-工业建筑"  => :industrial
      }.freeze
      end

      # ==========================================
      # 规则查询
      # ==========================================
      def self.get_setback_distances(road_width_m, building_type = :civil)
        bracket = if road_width_m >= 40
                    :wide
                  elsif road_width_m > 15
                    :medium
                  else
                    :narrow
                  end

        entry = RULES[bracket][building_type]
        if entry[:uniform]
          { low: entry[:uniform].to_f, mid: entry[:uniform].to_f, high: entry[:uniform].to_f }
        else
          { low: entry[:low].to_f, mid: entry[:mid].to_f, high: entry[:high].to_f }
        end
      end

      # ==========================================
      # 水系/绿地退让查询（蓝线/绿线）
      # ==========================================
      def self.get_water_green_setback(building_type)
        d = building_type == :old_city ? 6.0 : 10.0
        { low: d, mid: d, high: d }
      end

      # ==========================================
      # 边分组（将同一圆弧的多段线段合为一组）
      # ==========================================
      def self.group_edge_groups(face)
        edges = face.outer_loop.edges
        return [] if edges.empty?

        groups = []
        current = [edges[0]]
        current_curve = edges[0].curve

        (1...edges.length).each do |i|
          e = edges[i]
          if e.curve && current_curve && e.curve == current_curve
            current << e
          else
            groups << current
            current = [e]
            current_curve = e.curve
          end
        end
        groups << current

        groups
      end

      # ==========================================
      # 获取边组信息（供对话框识别边组）
      # ==========================================
      def self.get_edge_group_info(face)
        edges = face.outer_loop.edges
        groups = group_edge_groups(face)
        groups.map do |group|
          first_idx = edges.index(group[0])
          label = if group.length == 1
                    "第 #{first_idx + 1}/#{edges.length} 条边"
                  else
                    "第 #{first_idx + 1}-#{first_idx + group.length} 条边(圆弧)"
                  end
          { label: label, count: group.length, edges: group }
        end
      end

      # ==========================================
      # 图层管理
      # ==========================================
      def self.ensure_layers
        model = Sketchup.active_model
        LAYER_NAMES.each do |name|
          model.layers[name] || model.layers.add(name)
        end
      end

      # ==========================================
      # 多边形向内偏移（核心算法）
      # ==========================================
      def self.offset_polygon(vertices_3d, per_edge_inches, ref_z = nil, protected_mask = nil)
        n = vertices_3d.length
        return nil if n < 3 || per_edge_inches.length != n

        avg_z = ref_z || (vertices_3d.map(&:z).sum / n.to_f)

        # 投影到 2D，检测绕组方向
        pts_2d = vertices_3d.map { |v| Geom::Point3d.new(v.x, v.y, 0) }

        signed_area = 0.0
        n.times do |i|
          j = (i + 1) % n
          signed_area += pts_2d[i].x * pts_2d[j].y - pts_2d[j].x * pts_2d[i].y
        end
        is_ccw = signed_area > 0

        # 首次尝试（50% 边长限幅，曲线边跳过限幅）
        result = _compute_offset_clamped(per_edge_inches, pts_2d, avg_z, signed_area, is_ccw, 0.5, protected_mask)
        return result if result

        # 退线失败 → 简化多边形（移除过短边，让相邻长边延长相交）
        # 防止 1m 斜边衔接 90° 长边时退线折叠
        simplified = simplify_for_offset(vertices_3d, per_edge_inches, 3.0 / INCHES_PER_METER, protected_mask)
        return nil unless simplified

        offset_polygon(simplified[:vertices], simplified[:distances], ref_z, simplified[:protected_mask])
      end

      # ==========================================
      # 带限幅因子的偏移计算（内部方法）
      # ==========================================
      def self._compute_offset_clamped(per_edge_inches, pts_2d, avg_z, signed_area, is_ccw, clamp_factor, protected_mask = nil)
        n = pts_2d.length

        # 短边偏移限幅：若偏移距离超过边长 × clamp_factor，则压缩
        # 但跳过曲线边（protected_mask[i] == true），因为圆弧线段虽短但整体形成平滑曲线，
        # 限幅会导致退线距离严重不足（所有高度退线重叠在边界附近）
        clamped_dists = per_edge_inches.dup
        n.times do |i|
          next if protected_mask && protected_mask[i]
          j = (i + 1) % n
          edge_len = pts_2d[i].distance(pts_2d[j])
          limit = edge_len * clamp_factor
          if edge_len > 1e-8 && clamped_dists[i] > limit
            clamped_dists[i] = limit
          end
        end

        # 每条边计算方向向量和向内法线
        last_dir_x = 1.0
        last_dir_y = 0.0
        edges = []
        n.times do |i|
          j = (i + 1) % n
          dx = pts_2d[j].x - pts_2d[i].x
          dy = pts_2d[j].y - pts_2d[i].y
          len = Math.sqrt(dx * dx + dy * dy)

          if len > 1e-8
            dir_x = dx / len
            dir_y = dy / len
            last_dir_x = dir_x
            last_dir_y = dir_y
          else
            # 退化边（零长度），使用上一条边的方向
            dir_x = last_dir_x
            dir_y = last_dir_y
          end

          # CCW: 向内法线 = (-dy, dx)，CW: 向内法线 = (dy, -dx)
          if is_ccw
            n_x = -dir_y
            n_y =  dir_x
          else
            n_x =  dir_y
            n_y = -dir_x
          end

          edges << {
            dir:    Geom::Vector3d.new(dir_x, dir_y, 0),
            normal: Geom::Vector3d.new(n_x, n_y, 0),
            d_inch: clamped_dists[i].to_f,
            origin: pts_2d[i]
          }
        end

        m = edges.length
        return nil if m < 3

        new_pts = []
        m.times do |i|
          prev = (i - 1 + m) % m

          # 构建偏移边线：原点 + 法线 × 偏移距离
          d_prev = edges[prev][:d_inch]
          d_cur  = edges[i][:d_inch]

          offset_a = Geom::Vector3d.new(
            edges[prev][:normal].x * d_prev,
            edges[prev][:normal].y * d_prev,
            0
          )
          offset_b = Geom::Vector3d.new(
            edges[i][:normal].x * d_cur,
            edges[i][:normal].y * d_cur,
            0
          )

          pt_a = Geom::Point3d.new(
            edges[prev][:origin].x + offset_a.x,
            edges[prev][:origin].y + offset_a.y,
            0
          )
          pt_b = Geom::Point3d.new(
            edges[i][:origin].x + offset_b.x,
            edges[i][:origin].y + offset_b.y,
            0
          )

          line_a = [pt_a, edges[prev][:dir]]
          line_b = [pt_b, edges[i][:dir]]

          intersection = Geom.intersect_line_line(line_a, line_b)
          if intersection.is_a?(Geom::Point3d)
            new_pts << Geom::Point3d.new(intersection.x, intersection.y, avg_z)
          else
            # 相邻边平行（共线），回退到沿法线偏移
            new_pts << Geom::Point3d.new(pt_b.x, pt_b.y, avg_z)
          end
        end

        # 清理自相交（短边导致的退线交叉）
        cleaned = clean_self_intersecting_polygon(new_pts)
        return nil if cleaned.nil? || cleaned.length < 3
        new_pts = cleaned

        # 检查偏移后绕组是否反转（退化检测）
        new_area = 0.0
        new_pts.length.times do |i|
          j = (i + 1) % new_pts.length
          new_area += new_pts[i].x * new_pts[j].y - new_pts[j].x * new_pts[i].y
        end
        return nil if (new_area > 0) != (signed_area > 0)

        new_pts
      end

      # ==========================================
      # 多边形简化：移除长度小于 min_length_inch 的短边
      # 让相邻两边延长相交，替换两条短边顶点
      # 返回 { vertices:, distances:, protected_mask: } 或 nil
      # protected_mask: 布尔数组，标记不可移除的边（如焊接曲线中的线段）
      # ==========================================
      def self.simplify_for_offset(vertices_3d, per_edge_inches, min_length_inch, protected_mask = nil)
        n = vertices_3d.length
        return nil if n < 4

        pts = vertices_3d.map { |v| Geom::Point3d.new(v.x, v.y, 0) }
        dists = per_edge_inches.dup
        mask = protected_mask.dup if protected_mask
        avg_z = vertices_3d.map(&:z).sum / n.to_f

        # 只移除一条最短边（避免过度简化）
        shortest_i = nil
        shortest_len = Float::INFINITY

        n.times do |i|
          j = (i + 1) % n
          len = pts[i].distance(pts[j])
          next if len <= 1e-8 || len >= min_length_inch
          next if mask && mask[i]  # 跳过受保护的边（如焊接曲线中的线段）
          if len < shortest_len
            shortest_i = i
            shortest_len = len
          end
        end

        return nil if shortest_i.nil?

        i = shortest_i
        j = (i + 1) % n
        prev = (i - 1 + n) % n
        nxt = (j + 1) % n

        # 延长相邻两边求交点
        line1 = [pts[prev], pts[prev].vector_to(pts[i])]
        line2 = [pts[j], pts[j].vector_to(pts[nxt])]
        intersection = Geom.intersect_line_line(line1, line2)

        if intersection.is_a?(Geom::Point3d)
          vnew = Geom::Point3d.new(intersection.x, intersection.y, 0)
        else
          # 相邻边平行，退回到删除 j 顶点
          vnew = pts[prev]  # 让 prev→i→nxt 连成一条线
        end

        if i == n - 1
          # 环绕情况：短边是最后一条边 En-1(Vn-1→V0)
          new_pts = [vnew] + pts[1...-1]
          new_dists = dists[0...-1]  # 移除 dn-1
          new_mask = mask ? mask[0...-1] : nil
        else
          new_pts = pts[0...i] + [vnew] + pts[(i + 2)..-1]
          new_dists = dists[0...i] + dists[(i + 1)..-1]  # 移除 di
          new_mask = mask ? mask[0...i] + mask[(i + 1)..-1] : nil
        end

        return nil if new_pts.length < 3

        new_vertices = new_pts.map { |p| Geom::Point3d.new(p.x, p.y, avg_z) }
        result = { vertices: new_vertices, distances: new_dists }
        result[:protected_mask] = new_mask if mask
        result
      end

      # ==========================================
      # 自相交清理（移除短边导致的退线交叉折叠）
      # ==========================================
      def self.clean_self_intersecting_polygon(vertices_3d)
        n = vertices_3d.length
        return vertices_3d if n < 4

        avg_z = vertices_3d.map(&:z).sum / n.to_f
        pts = vertices_3d.map { |v| Geom::Point3d.new(v.x, v.y, 0) }
        tolerance = 0.01  # 英寸容差

        # 迭代清理：每次找到一处自相交并移除折叠段
        result = pts.dup
        20.times do
          break if result.length < 4
          m = result.length
          found = false

          m.times do |i|
            i_next = (i + 1) % m
            # 只检查非相邻边对：jj 从 i+2 到 i+m-2（模 m 取余处理环绕）
            ((i + 2)...(i - 1 + m)).each do |jj|
              j = jj % m
              j_next = (j + 1) % m

              line1 = [result[i], result[i].vector_to(result[i_next])]
              line2 = [result[j], result[j].vector_to(result[j_next])]
              pt = Geom.intersect_line_line(line1, line2)

              if pt.is_a?(Geom::Point3d)
                # 确认交点在两边段内部
                len1 = result[i].distance(result[i_next])
                len2 = result[j].distance(result[j_next])
                d1a = result[i].distance(pt)
                d1b = result[i_next].distance(pt)
                d2a = result[j].distance(pt)
                d2b = result[j_next].distance(pt)
                on1 = (d1a + d1b - len1).abs < tolerance && d1a < len1 && d1b < len1
                on2 = (d2a + d2b - len2).abs < tolerance && d2a < len2 && d2b < len2

                if on1 && on2
                  # 移除 i_next..j 之间的顶点，加入交点
                  inter_pt = Geom::Point3d.new(pt.x, pt.y, avg_z)
                  new_result = [inter_pt]
                  k = (j_next) % m
                  while k != (i_next) % m
                    new_result << Geom::Point3d.new(result[k].x, result[k].y, avg_z)
                    k = (k + 1) % m
                  end
                  result = new_result
                  found = true
                  break
                end
              end
            end
            break if found
          end
          break unless found
        end

        result.length >= 3 ? result : nil
      end

      # ==========================================
      # 计算三个高度段的退线多边形
      # ==========================================
      def self.compute_all_offset_polygons(vertices_3d, edge_distances_inch, protected_mask = nil)
        # edge_distances_inch: Array of { low: inches, mid: inches, high: inches }
        # 统一使用一个 Z 参考值，确保三条退线在同一平面
        ref_z = vertices_3d.map(&:z).sum / vertices_3d.length.to_f
        HEIGHT_CATEGORIES.map do |key|
          dists = edge_distances_inch.map { |h| h[key] }
          offset_polygon(vertices_3d, dists, ref_z, protected_mask)
        end
      end

      # ==========================================
      # 绘制退线
      # ==========================================
      def self.draw_setback_polygons(offset_arrays)
        model = Sketchup.active_model
        ensure_layers

        # 将本次所有退线放入一个群组，群组本身存放在"未标记"(Layer0)
        group = model.active_entities.add_group
        tag0 = model.layers["Layer0"] || model.layers[0]
        group.layer = tag0 if tag0
        group_entities = group.entities

        offset_arrays.each_with_index do |pts, idx|
          next unless pts && pts.length >= 3

          layer = model.layers[LAYER_NAMES[idx]]
          pts.each_with_index do |pt, i|
            next_pt = pts[(i + 1) % pts.length]
            edge = group_entities.add_line(pt, next_pt)
            edge.layer = layer if edge
          end
        end
      end

      # ==========================================
      # 完整流程：处理一个面
      # ==========================================
      def self.process_face(face, transform, building_type, pre_collected_values = nil)
        edges = face.outer_loop.edges
        vertices_local = face.outer_loop.vertices.map(&:position)
        vertices_world = vertices_local.map { |pt| pt.transform(transform) }

        edge_count = edges.length
        return false if edge_count < 3

        # 构建受保护边掩码：焊接曲线中的线段不可被简化移除
        edge_groups_protect = group_edge_groups(face)
        protected_mask = Array.new(edge_count, false)
        edge_groups_protect.each do |group|
          if group.length > 1 && group[0].curve
            group.each { |e| protected_mask[edges.index(e)] = true if edges.index(e) }
          end
        end

        model = Sketchup.active_model

        # 收集每条边的退线距离
        edge_distances_m = []

        if pre_collected_values
          # 使用预先收集的值（来自 UI 对话框），按组展开到每条边
          groups = group_edge_groups(face)
          groups.each_with_index do |group, idx|
            d = pre_collected_values[idx]
            group.length.times { edge_distances_m << d }
          end
        else
          # 原有逻辑：将边分组，每组弹一次窗
          edge_groups = group_edge_groups(face)

          edge_groups.each do |group|
            # 高亮组内所有边
            model.selection.clear
            group.each { |e| model.selection.add(e) }

            # 构建提示文本
            first_idx = edges.index(group[0])
            label = if group.length == 1
                      "第 #{first_idx + 1}/#{edge_count} 条边"
                    else
                      "第 #{first_idx + 1}-#{first_idx + group.length} 条边(圆弧)"
                    end

            prompts = ["#{label}相邻道路红线宽度(米):\n(若相邻绿线填 G, 若相邻蓝线填 E)"]
            defaults = ["15"]
            results = UI.inputbox(prompts, defaults, "建筑退线设置")

            model.selection.clear
            return false if results == false

            raw = results[0].strip.downcase
            distances = if raw == 'g' || raw == 'e'
                          get_water_green_setback(building_type)
                        else
                          get_setback_distances(raw.to_f, building_type)
                        end

            group.length.times { edge_distances_m << distances }
          end
        end

        # 米 → 英寸
        edge_distances_inch = edge_distances_m.map do |d|
          {
            low:  d[:low]  / INCHES_PER_METER,
            mid:  d[:mid]  / INCHES_PER_METER,
            high: d[:high] / INCHES_PER_METER
          }
        end

        # 计算三个偏移多边形
        offset_arrays = compute_all_offset_polygons(vertices_world, edge_distances_inch, protected_mask)

        # 绘制
        model.start_operation("绘制建筑退线", true)
        begin
          draw_setback_polygons(offset_arrays)
          model.commit_operation
        rescue => e
          model.abort_operation
          UI.messagebox("绘制退线失败: #{e.message}")
          return false
        end

        true
      end

    end
  end
end
