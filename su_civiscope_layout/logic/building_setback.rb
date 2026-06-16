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
      # 相邻用地退让查询
      # ==========================================
      def self.get_adjacent_land_setback
        { low: 7.2, mid: 12.0, high: 12.0 }
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
      # 线-圆求交（用于直线边与圆弧边的偏移交点）
      # ==========================================
      def self._line_circle_intersect(line_origin, line_dir, circle_center, circle_radius)
        dx = line_dir.x.to_f; dy = line_dir.y.to_f
        ox = line_origin.x.to_f - circle_center.x.to_f
        oy = line_origin.y.to_f - circle_center.y.to_f

        a = dx * dx + dy * dy  # should be 1 for unit direction
        b = 2.0 * (dx * ox + dy * oy)
        c = ox * ox + oy * oy - circle_radius * circle_radius

        disc = b * b - 4.0 * a * c
        return nil if disc < -1e-8
        disc = 0.0 if disc < 0

        sqrt_disc = Math.sqrt(disc)
        inv_2a = 1.0 / (2.0 * a)

        t1 = (-b + sqrt_disc) * inv_2a
        t2 = (-b - sqrt_disc) * inv_2a

        p1 = Geom::Point3d.new(line_origin.x.to_f + t1 * dx, line_origin.y.to_f + t1 * dy, 0)
        p2 = Geom::Point3d.new(line_origin.x.to_f + t2 * dx, line_origin.y.to_f + t2 * dy, 0)
        [p1, p2]
      end

      # ==========================================
      # 圆-圆求交（用于两个不同圆弧边的偏移交点）
      # ==========================================
      def self._circle_circle_intersect(c1, r1, c2, r2)
        d = c1.distance(c2).to_f
        return nil if d < 1e-12 && (r1 - r2).abs < 1e-12  # same circle
        return nil if d > r1 + r2 + 1e-8 || d < (r1 - r2).abs - 1e-8

        a = (r1 * r1 - r2 * r2 + d * d) / (2.0 * d)
        h_sq = r1 * r1 - a * a
        h = h_sq > 0 ? Math.sqrt(h_sq) : 0.0

        mid_x = c1.x.to_f + a * (c2.x.to_f - c1.x.to_f) / d
        mid_y = c1.y.to_f + a * (c2.y.to_f - c1.y.to_f) / d

        hdx = h * (c2.y.to_f - c1.y.to_f) / d
        hdy = h * (c2.x.to_f - c1.x.to_f) / d

        p1 = Geom::Point3d.new(mid_x + hdx, mid_y - hdy, 0)
        p2 = Geom::Point3d.new(mid_x - hdx, mid_y + hdy, 0)
        [p1, p2]
      end

      # 从两个交点中选出更接近 target 的那个
      def self._pick_nearest(points, target)
        return points.first if points.length == 1
        p1, p2 = points
        d1 = p1.distance(target).to_f
        d2 = p2.distance(target).to_f
        d1 <= d2 ? p1 : p2
      end

      # ==========================================
      # 多边形向内偏移（核心算法）
      # ==========================================
      def self.offset_polygon(vertices_3d, per_edge_inches, ref_z = nil, protected_mask = nil, arc_meta = nil, arc_segments_out = nil)
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
        result = _compute_offset_clamped(per_edge_inches, pts_2d, avg_z, signed_area, is_ccw, 0.5, protected_mask, arc_meta, arc_segments_out)
        return result if result

        # 退线失败 → 简化多边形（移除过短边，让相邻长边延长相交）
        simplified = simplify_for_offset(vertices_3d, per_edge_inches, 3.0 / INCHES_PER_METER, protected_mask)
        return nil unless simplified

        offset_polygon(simplified[:vertices], simplified[:distances], ref_z, simplified[:protected_mask], arc_meta, arc_segments_out)
      end

      # ==========================================
      # 带限幅因子的偏移计算（内部方法）
      # arc_meta: 与 pts_2d 等长的数组，nil 或 { center:, radius:, group_id: }
      # ==========================================
      def self._compute_offset_clamped(per_edge_inches, pts_2d, avg_z, signed_area, is_ccw, clamp_factor, protected_mask = nil, arc_meta = nil, arc_segments_out = nil)
        n = pts_2d.length

        # 检测切角边（短直线，两侧邻边角度差 > 20° 且比自身长）
        corner_mask = Array.new(n, false)
        n.times do |i|
          prev_i = (i - 1 + n) % n; next_i = (i + 1) % n; j = (i + 1) % n
          ei_dx = pts_2d[j].x - pts_2d[i].x; ei_dy = pts_2d[j].y - pts_2d[i].y
          ei_len = Math.sqrt(ei_dx * ei_dx + ei_dy * ei_dy)
          next if ei_len < 0.01
          ei_dx /= ei_len; ei_dy /= ei_len

          pj = pts_2d[prev_i]; enext_j = (next_i + 1) % n
          eprev_len = pts_2d[i].distance(pj)
          enext_len = pts_2d[next_i].distance(pts_2d[enext_j])
          next if eprev_len < 0.01 || enext_len < 0.01

          cos_p = ei_dx * (pts_2d[i].x - pj.x) / eprev_len + ei_dy * (pts_2d[i].y - pj.y) / eprev_len
          cos_n = ei_dx * (pts_2d[enext_j].x - pts_2d[next_i].x) / enext_len + ei_dy * (pts_2d[enext_j].y - pts_2d[next_i].y) / enext_len
          ang_p = Math.acos([cos_p.abs, 1.0].min) * 57.29578
          ang_n = Math.acos([cos_n.abs, 1.0].min) * 57.29578

          if ang_p > 20.0 && ang_n > 20.0 && ei_len < eprev_len * 0.8 && ei_len < enext_len * 0.8
            corner_mask[i] = true
          end
        end

        # 短边偏移限幅：跳过曲线边和切角边
        clamped_dists = per_edge_inches.dup
        n.times do |i|
          next if protected_mask && protected_mask[i]
          next if corner_mask[i]
          j = (i + 1) % n
          edge_len = pts_2d[i].distance(pts_2d[j])
          limit = edge_len * clamp_factor
          if edge_len > 1e-8 && clamped_dists[i] > limit
            clamped_dists[i] = limit
          end
        end

        # -------------------------------------------------------
        # 将边分组为"runs"（连续同类型边）
        # -------------------------------------------------------
        runs = []  # { type: :straight|:arc, start_idx:, end_idx:, ... }
        i = 0
        while i < n
          am = arc_meta && arc_meta[i]
          if am
            gid = am[:group_id]
            start_i = i
            while i < n && arc_meta[i] && arc_meta[i][:group_id] == gid
              i += 1
            end
            runs << { type: :arc, start_idx: start_i, end_idx: i - 1,
                      center: am[:center], radius: am[:radius],
                      d_inch: clamped_dists[start_i], group_id: gid }
          else
            runs << { type: :straight, idx: i, d_inch: clamped_dists[i] }
            i += 1
          end
        end

        # 合并环绕的弧（同一 ArcCurve 跨 edges 首尾）
        if runs.length >= 2 && runs[0][:type] == :arc && runs[-1][:type] == :arc
          c0 = runs[0][:center]; c1 = runs[-1][:center]
          if c0.distance(c1) < 0.001 && (runs[0][:radius] - runs[-1][:radius]).abs < 0.001
            runs[0][:start_idx] = runs[-1][:start_idx]  # 首尾合并
            runs.pop
          end
        end

        # 纯圆弧多边形：所有 edges 属于同一弧组 → 生成同心偏移圆
        if runs.length == 1 && runs[0][:type] == :arc
          run = runs[0]
          r_new = run[:radius] - run[:d_inch]
          return nil if r_new <= 1e-6
          # 在偏移圆上采样（使用原多边形的顶点数）
          center = run[:center]
          step = (2.0 * Math::PI) / n
          pts = (0...n).map do |k|
            angle = step * k
            Geom::Point3d.new(
              center.x + r_new * Math.cos(angle),
              center.y + r_new * Math.sin(angle), avg_z)
          end
          return pts
        end

        # -------------------------------------------------------
        # 为每个 straight run 计算偏移直线
        # -------------------------------------------------------
        last_dir_x = 1.0; last_dir_y = 0.0
        runs.each do |run|
          next unless run[:type] == :straight
          idx = run[:idx]
          j = (idx + 1) % n
          dx = pts_2d[j].x - pts_2d[idx].x
          dy = pts_2d[j].y - pts_2d[idx].y
          len = Math.sqrt(dx * dx + dy * dy)
          if len > 1e-8
            run[:dir_x] = dx / len; run[:dir_y] = dy / len
            last_dir_x = run[:dir_x]; last_dir_y = run[:dir_y]
          else
            run[:dir_x] = last_dir_x; run[:dir_y] = last_dir_y
          end
          if is_ccw
            run[:n_x] = -run[:dir_y]; run[:n_y] = run[:dir_x]
          else
            run[:n_x] = run[:dir_y]; run[:n_y] = -run[:dir_x]
          end
          d = run[:d_inch]
          run[:offset_org] = Geom::Point3d.new(
            pts_2d[idx].x + run[:n_x] * d,
            pts_2d[idx].y + run[:n_y] * d, 0)
          run[:offset_dir] = Geom::Vector3d.new(run[:dir_x], run[:dir_y], 0)
          run[:normal] = Geom::Vector3d.new(run[:n_x], run[:n_y], 0)
        end

        # -------------------------------------------------------
        # 辅助：将点投影到直线上
        # -------------------------------------------------------
        project_onto = ->(pt, line_org, line_dir) {
          vx = pt.x - line_org.x; vy = pt.y - line_org.y
          t = vx * line_dir.x + vy * line_dir.y
          Geom::Point3d.new(line_org.x + t * line_dir.x, line_org.y + t * line_dir.y, avg_z)
        }

        # -------------------------------------------------------
        # 辅助：计算倒角弧（两偏移直线之间的切点）
        # 返回 { t1:, t2:, center:, radius: } （radius<=0 表示无弧）
        # -------------------------------------------------------
        fillet_tangents = ->(line1, line2, arc) {
          r_f = arc[:radius] - arc[:d_inch]
          if r_f <= 1e-6
            inter = Geom.intersect_line_line(
              [line1[:offset_org], line1[:offset_dir]],
              [line2[:offset_org], line2[:offset_dir]])
            pt = inter.is_a?(Geom::Point3d) ? inter : line1[:offset_org]
            return { t1: pt, t2: pt, center: nil, radius: 0 }
          end
          # 倒角圆心：从两条 offset 直线向内部偏移 r_f 后的交点
          pt1 = Geom::Point3d.new(
            line1[:offset_org].x + line1[:n_x] * r_f,
            line1[:offset_org].y + line1[:n_y] * r_f, 0)
          pt2 = Geom::Point3d.new(
            line2[:offset_org].x + line2[:n_x] * r_f,
            line2[:offset_org].y + line2[:n_y] * r_f, 0)
          inter = Geom.intersect_line_line(
            [pt1, line1[:offset_dir]],
            [pt2, line2[:offset_dir]])
          fc = inter.is_a?(Geom::Point3d) ? inter : Geom::Point3d.new(
            (pt1.x + pt2.x) / 2.0, (pt1.y + pt2.y) / 2.0, 0)
          t1 = project_onto.call(fc, line1[:offset_org], line1[:offset_dir])
          t2 = project_onto.call(fc, line2[:offset_org], line2[:offset_dir])
          { t1: t1, t2: t2, center: fc, radius: r_f }
        }

        # -------------------------------------------------------
        # 按 run 遍历，每个 transition 添加顶点
        # Straight→Arc 时一次性添加两个切点(arc开始+arc结束)，
        # 然后跳过紧接的 Arc→Straight transition
        # -------------------------------------------------------
        m = runs.length
        new_pts = []
        skip_next = false

        m.times do |i|
          # 若上一轮 straight→arc 已预填切点，本轮 arc→straight 直接跳过
          if skip_next
            curr = runs[i]
            nxt = runs[(i + 1) % m]
            # 仅当确实处于 arc→straight 时才消费 skip_next
            if curr[:type] == :arc && nxt[:type] == :straight
              skip_next = false
              next
            end
            # 否则是意外状态，重置并继续正常处理
            skip_next = false
          end

          curr = runs[i]
          nxt = runs[(i + 1) % m]

          if curr[:type] == :straight && nxt[:type] == :straight
            # 直线 × 直线：偏移线的交点
            inter = Geom.intersect_line_line(
              [curr[:offset_org], curr[:offset_dir]],
              [nxt[:offset_org], nxt[:offset_dir]])
            if inter.is_a?(Geom::Point3d)
              new_pts << Geom::Point3d.new(inter.x, inter.y, avg_z)
            else
              new_pts << Geom::Point3d.new(curr[:offset_org].x, curr[:offset_org].y, avg_z)
            end

          elsif curr[:type] == :straight && nxt[:type] == :arc
            # 直线 → 弧 → 直线：用倒角弧连接两条 offset 直线
            after_run = runs[(i + 2) % m]
            if after_run[:type] == :straight
              ft = fillet_tangents.call(curr, after_run, nxt)
              new_pts << Geom::Point3d.new(ft[:t1].x, ft[:t1].y, avg_z)
              new_pts << Geom::Point3d.new(ft[:t2].x, ft[:t2].y, avg_z)
              if arc_segments_out && ft[:radius] > 1e-6
                arc_segments_out << {
                  center: ft[:center],
                  radius: ft[:radius],
                  start_pt: Geom::Point3d.new(ft[:t1].x, ft[:t1].y, avg_z),
                  end_pt:   Geom::Point3d.new(ft[:t2].x, ft[:t2].y, avg_z)
                }
              end
              skip_next = true  # 下一轮是弧→直线，切点已添加，跳过
            else
              # 退化情况：连续两个不同弧组 — 用圆-圆求交
              r1 = nxt[:radius] - nxt[:d_inch]
              r2 = after_run[:radius] - after_run[:d_inch]
              if r1 > 1e-6 && r2 > 1e-6
                pts = _circle_circle_intersect(nxt[:center], r1, after_run[:center], r2)
                if pts
                  mid = Geom::Point3d.new(
                    (pts_2d[nxt[:end_idx]].x + pts_2d[after_run[:start_idx]].x) / 2.0,
                    (pts_2d[nxt[:end_idx]].y + pts_2d[after_run[:start_idx]].y) / 2.0, 0)
                  new_pts << Geom::Point3d.new(_pick_nearest(pts, mid).x, _pick_nearest(pts, mid).y, avg_z)
                else
                  new_pts << Geom::Point3d.new(pts_2d[nxt[:end_idx]].x, pts_2d[nxt[:end_idx]].y, avg_z)
                end
              elsif r1 <= 1e-6
                new_pts << Geom::Point3d.new(nxt[:center].x, nxt[:center].y, avg_z)
              else
                new_pts << Geom::Point3d.new(after_run[:center].x, after_run[:center].y, avg_z)
              end
            end

          elsif curr[:type] == :arc && nxt[:type] == :straight
            # 弧→直线（弧前没有与之配对的 straight——如弧跑到了 runs 开头）
            prev_run = runs[(i - 1 + m) % m]
            if prev_run[:type] == :arc && prev_run[:group_id] == curr[:group_id]
              # 同一弧组内：在切换到直线之前径向投影弧的终点
              r_new = curr[:radius] - curr[:d_inch]
              if r_new > 1e-6
                px = curr[:center].x + (pts_2d[nxt[:idx]].x - curr[:center].x) * r_new / curr[:radius]
                py = curr[:center].y + (pts_2d[nxt[:idx]].y - curr[:center].y) * r_new / curr[:radius]
                new_pts << Geom::Point3d.new(px, py, avg_z)
              end
            end
            # 正常流程中 (straight→arc 已处理) 不会到达这里

          elsif curr[:type] == :arc && nxt[:type] == :arc
            if curr[:group_id] == nxt[:group_id]
              # 同一弧组内：径向投影
              r_new = curr[:radius] - curr[:d_inch]
              if r_new <= 1e-6
                new_pts << Geom::Point3d.new(curr[:center].x, curr[:center].y, avg_z)
              else
                pt = pts_2d[curr[:end_idx]]  # 两弧段交接顶点
                dx = pt.x - curr[:center].x; dy = pt.y - curr[:center].y
                dist = Math.sqrt(dx * dx + dy * dy)
                if dist > 1e-8
                  scale = r_new / dist
                  new_pts << Geom::Point3d.new(curr[:center].x + dx * scale, curr[:center].y + dy * scale, avg_z)
                else
                  new_pts << Geom::Point3d.new(curr[:center].x, curr[:center].y, avg_z)
                end
              end
            else
              # 不同弧组：圆-圆求交
              r1 = curr[:radius] - curr[:d_inch]
              r2 = nxt[:radius] - nxt[:d_inch]
              if r1 > 1e-6 && r2 > 1e-6
                pts = _circle_circle_intersect(curr[:center], r1, nxt[:center], r2)
                if pts
                  mid = Geom::Point3d.new(
                    (pts_2d[curr[:end_idx]].x + pts_2d[nxt[:start_idx]].x) / 2.0,
                    (pts_2d[curr[:end_idx]].y + pts_2d[nxt[:start_idx]].y) / 2.0, 0)
                  new_pts << Geom::Point3d.new(_pick_nearest(pts, mid).x, _pick_nearest(pts, mid).y, avg_z)
                else
                  new_pts << Geom::Point3d.new(pts_2d[curr[:end_idx]].x, pts_2d[curr[:end_idx]].y, avg_z)
                end
              elsif r1 <= 1e-6
                new_pts << Geom::Point3d.new(curr[:center].x, curr[:center].y, avg_z)
              else
                new_pts << Geom::Point3d.new(nxt[:center].x, nxt[:center].y, avg_z)
              end
            end
          end
        end

        return nil if new_pts.length < 3

        # 去重连续重复点
        deduped = [new_pts.first]
        (1...new_pts.length).each do |k|
          deduped << new_pts[k] unless new_pts[k].distance(new_pts[k-1]) < 0.001
        end
        if deduped.length > 1 && deduped.first.distance(deduped.last) < 0.001
          deduped.pop
        end
        return nil if deduped.length < 3
        new_pts = deduped

        # 清理自相交
        cleaned = clean_self_intersecting_polygon(new_pts)
        return nil if cleaned.nil? || cleaned.length < 3
        new_pts = cleaned

        # 检查偏移后绕组是否反转
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

              next if result[i].distance(result[i_next]) < 1e-8
              next if result[j].distance(result[j_next]) < 1e-8
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
      def self.compute_all_offset_polygons(vertices_3d, edge_distances_inch, protected_mask = nil, arc_meta = nil)
        ref_z = vertices_3d.map(&:z).sum / vertices_3d.length.to_f
        polygons = []
        all_arc_segments = []
        HEIGHT_CATEGORIES.each_with_index do |key, idx|
          dists = edge_distances_inch.map { |h| h[key] }
          arc_segs = []
          poly = offset_polygon(vertices_3d, dists, ref_z, protected_mask, arc_meta, arc_segs)
          polygons << poly
          all_arc_segments << arc_segs
        end
        { polygons: polygons, arc_segments: all_arc_segments }
      end

      # ==========================================
      # 绘制退线
      # ==========================================
      def self.draw_setback_polygons(offset_arrays, arc_segments_per_layer = nil)
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
          arcs = arc_segments_per_layer ? arc_segments_per_layer[idx] : []

          # 收集被弧覆盖的边（按起点索引）
          arc_edge_indices = {}
          arcs.each do |arc|
            start_idx = pts.index { |p| p.distance(arc[:start_pt]) < 0.001 }
            arc_edge_indices[start_idx] = arc if start_idx
          end

          # 画直线边（跳过被弧覆盖的边）
          pts.each_with_index do |pt, i|
            next if arc_edge_indices.key?(i)
            next_pt = pts[(i + 1) % pts.length]
            edge = group_entities.add_line(pt, next_pt)
            edge.layer = layer if edge
          end

          # 画圆弧边
          arcs.each do |arc|
            next if arc[:radius] <= 1e-6
            center = arc[:center]
            r = arc[:radius]
            start_v = Geom::Vector3d.new(arc[:start_pt].x - center.x, arc[:start_pt].y - center.y, 0)
            end_v   = Geom::Vector3d.new(arc[:end_pt].x   - center.x, arc[:end_pt].y   - center.y, 0)

            xaxis = start_v.clone; xaxis.normalize!
            normal = Geom::Vector3d.new(0, 0, 1)
            # 从 start 到 end 的 CCW 弧度
            det = xaxis.x * end_v.y - xaxis.y * end_v.x
            dot = (xaxis.x * end_v.x + xaxis.y * end_v.y) / r
            end_angle = Math.atan2(det, dot)
            end_angle += 2.0 * Math::PI if end_angle <= 0

            # 用 add_arc 创建真正的圆弧（返回 edges 数组）
            arc_edges = group_entities.add_arc(
              Geom::Point3d.new(center.x, center.y, arc[:start_pt].z),
              xaxis, normal, r, 0.0, end_angle, 12)
            if arc_edges.is_a?(Array)
              arc_edges.each { |e| e.layer = layer if e }
            end
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

        # 构建受保护边掩码 + 圆弧元数据
        edge_groups_protect = group_edge_groups(face)
        protected_mask = Array.new(edge_count, false)
        arc_meta = Array.new(edge_count, nil)  # nil for straight edges

        edge_groups_protect.each do |group|
          if group.length > 1 && group[0].curve && group[0].curve.is_a?(Sketchup::ArcCurve)
            curve = group[0].curve
            center_world = curve.center.transform(transform)
            radius_inch = curve.radius.to_f
            gid = edge_groups_protect.index(group)
            group.each do |e|
              idx = edges.index(e)
              if idx
                protected_mask[idx] = true
                arc_meta[idx] = { center: center_world, radius: radius_inch, group_id: gid }
              end
            end
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
        offset_result = compute_all_offset_polygons(vertices_world, edge_distances_inch, protected_mask, arc_meta)

        # 绘制
        model.start_operation("绘制建筑退线", true)
        begin
          draw_setback_polygons(offset_result[:polygons], offset_result[:arc_segments])
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
