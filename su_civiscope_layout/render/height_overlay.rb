# 编码：UTF-8
require 'set'

module CiviscopeLayout
  module Core
    
    class CiviscopeHeightCheckOverlay < Sketchup::Overlay
      attr_accessor :sites_data
      
      def initialize
        super("civiscope_height_check", "地块限高检测")
        @sites_data = {} # { id_str => { local_pts: [], violated: false } }
      end
      
      def draw(view)
        model = Sketchup.active_model
        @sites_data.each do |id_str, data|
          site = model.find_entity_by_persistent_id(id_str.to_i)
          site ||= model.entities.to_a.find { |e| CiviscopeLayout::Core.get_short_id(e) == id_str }
          next unless site
          
          limit_m = site.get_attribute("dynamic_attributes", "height_limit").to_f
          next if limit_m <= 0
          
          # 检查当前活动路径
          active_path = model.active_path || []
          
          # 判断用户是否在 CIM 地块内部
          # 方法1：检查 CIM 地块实例是否在活动路径中（适用于组件实例）
          site_in_path = active_path.include?(site)
          
          # 方法2：检查当前活动 entities 的 parent 是否是 CIM 地块的 definition（适用于组）
          unless site_in_path
            active_entities = model.active_entities
            if active_entities && active_entities.parent
              site_definition = site.is_a?(Sketchup::Group) ? site.definition : site.definition
              if active_entities.parent == site_definition
                site_in_path = true
              end
            end
          end
          
          local_pts = data[:local_pts]
          
          if site_in_path
            # 用户在 CIM 地块内部
            # view 的坐标系是 CIM 地块内部的坐标系
            # local_pts 已经是 CIM 地块内部的局部坐标，直接使用
            pts = local_pts
          else
            # 用户在 CIM 地块外部
            # view 的坐标系是世界坐标系
            # 需要将 local_pts 转换到世界坐标系
            tr_world = CiviscopeLayout::Core.get_full_world_transform(site)
            pts = local_pts.map { |p| p.transform(tr_world) }
          end
          
          limit_inch = limit_m / 0.0254
          is_violated = data[:violated]
          
          color = is_violated ? Sketchup::Color.new(255, 0, 0, 70) : Sketchup::Color.new(150, 150, 150, 70)
          edge_color = is_violated ? Sketchup::Color.new(255, 0, 0, 150) : Sketchup::Color.new(100, 100, 100, 150)
          
          top_pts = pts.map { |p| p.offset([0, 0, limit_inch]) }
          
          pts.each_with_index do |p, i|
            p2 = pts[(i + 1) % pts.length]
            t1 = top_pts[i]
            t2 = top_pts[(i + 1) % top_pts.length]
            view.drawing_color = color
            view.draw(GL_QUADS, p, p2, t2, t1)
            view.drawing_color = edge_color
            view.line_width = 1
            view.draw(GL_LINE_STRIP, p, p2, t2, t1, p)
          end
          view.drawing_color = color
          view.draw(GL_POLYGON, top_pts)
          view.drawing_color = edge_color
          view.draw(GL_LINE_LOOP, top_pts)
        end
      end
    end

    def self.ensure_height_check_overlay(model)
      @overlay ||= CiviscopeHeightCheckOverlay.new
      begin
        model.overlays.add(@overlay) unless model.overlays.to_a.include?(@overlay)
      rescue => e; end
    end

    def self.do_toggle_height_check(id_str)
      model = Sketchup.active_model
      site = model.find_entity_by_persistent_id(id_str.to_i)
      site ||= model.entities.to_a.find { |e| self.get_short_id(e) == id_str }
      return unless site
      
      self.ensure_height_check_overlay(model)
      
      if @overlay.sites_data.key?(id_str)
        @overlay.sites_data.delete(id_str)
      else
        self.add_site_to_height_check(site)
      end
      UI.start_timer(0, false) { Sketchup.active_model.active_view.refresh }
      self.refresh_stats_ui(model.selection)
    end

    def self.do_set_all_height_checks(status_bool)
      model = Sketchup.active_model
      self.ensure_height_check_overlay(model)
      
      if status_bool
        # Scan all definitions and their instances for sites
        model.definitions.each do |d|
          next if d.image?
          d.instances.each do |inst| 
            if inst.get_attribute("dynamic_attributes", "site_func")
              self.add_site_to_height_check(inst)
            end
          end
        end
      else
        @overlay.sites_data.clear
      end
      
      model.active_view.invalidate
      UI.start_timer(0, false) { model.active_view.refresh }
      self.refresh_stats_ui(model.selection)
    end

    def self.add_site_to_height_check(site)
      id_str = self.get_short_id(site)
      return if @overlay.sites_data.key?(id_str)
      
      limit_m = site.get_attribute("dynamic_attributes", "height_limit").to_f
      return if limit_m <= 0
      
      definition = site.is_a?(Sketchup::Group) ? site.definition : (site.respond_to?(:definition) ? site.definition : nil)
      return unless definition
      
      local_pts = nil
      
      # 优先查找地块边线组
      boundary_group = definition.entities.grep(Sketchup::Group).find do |g|
        g.get_attribute("dynamic_attributes", "site_boundary") == "true"
      end
      
      if boundary_group
        # 从边线组提取顶点（需要考虑边线组的变换）
        edges = boundary_group.entities.grep(Sketchup::Edge)
        if edges.any?
          # 获取边线组的变换
          tr_boundary = boundary_group.transformation
          
          # 将边线顶点转换到组件局部坐标系
          local_pts = self.sort_vertices_by_connection_with_transform(edges, tr_boundary)
        end
      end
      
      # 如果没有边线组，使用原有逻辑（凸包）
      unless local_pts
        horizontal_faces = definition.entities.grep(Sketchup::Face).select { |f| f.normal.z.abs > 0.99 }
        
        if horizontal_faces.any?
          all_vertices = []
          horizontal_faces.each do |face|
            face.outer_loop.vertices.each do |v|
              all_vertices << v.position
            end
          end
          local_pts = self.compute_convex_hull(all_vertices)
        else
          b = definition.bounds
          local_pts = [b.corner(0), b.corner(1), b.corner(3), b.corner(2)]
        end
      end
      
      @overlay.sites_data[id_str] = { local_pts: local_pts, violated: false }
      self.update_overlay_state(id_str)
    end

    def self.update_overlay_state(id_str)
      return unless @overlay && @overlay.sites_data[id_str]
      data = @overlay.sites_data[id_str]
      model = Sketchup.active_model
      
      # Use persistent ID or custom traversal if needed
      site = model.find_entity_by_persistent_id(id_str.to_i)
      unless site
        # Search all definitions for instances matching the short ID (fallback)
        model.definitions.each do |d|
          site = d.instances.find { |i| self.get_short_id(i) == id_str }
          break if site
        end
      end
      return unless site && site.valid?
      
      tr_site = self.get_full_world_transform(site)
      limit_m = site.get_attribute("dynamic_attributes", "height_limit").to_f
      limit_inch = limit_m / 0.0254
      
      site_box = site.definition.bounds
      site_min_z = (tr_site * site_box.min).z
      
      # find_buildings_on_site now returns actual entities
      bldg_ents = self.find_buildings_on_site(site)
      is_violated = false
      
      bldg_ents.each do |b_ent|
        next unless b_ent.valid?
        tr_b = self.get_full_world_transform(b_ent)
        local_box = b_ent.definition.bounds
        
        # Check world max Z against site min Z + limit
        w_max_z = -100000000
        (0..7).each do |i| 
          z = (tr_b * local_box.corner(i)).z
          w_max_z = z if z > w_max_z 
        end
        
        if w_max_z > site_min_z + (limit_inch - 0.001)
          is_violated = true
          break
        end
      end
      data[:violated] = is_violated
    end

    # 计算凸包（convex hull）- Graham Scan算法
    def self.compute_convex_hull(points)
      return points if points.length <= 3
      
      # 找到最低点（y最小，如果y相同则x最小）
      start = points.min_by { |p| [p.y, p.x] }
      
      # 按极角排序
      sorted = points.sort_by do |p|
        if p == start
          -1 # 起点排在最前面
        else
          angle = Math.atan2(p.y - start.y, p.x - start.x)
          angle
        end
      end
      
      # Graham Scan
      hull = []
      sorted.each do |p|
        while hull.length >= 2 && self.cross_product(hull[-2], hull[-1], p) <= 0
          hull.pop
        end
        hull.push(p)
      end
      
      hull
    end

    # 计算叉积（用于判断方向）
    def self.cross_product(o, a, b)
      (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x)
    end

    # 按连接顺序排序顶点（构建闭合轮廓）
    def self.sort_vertices_by_connection(edges)
      return [] if edges.empty?
      
      # 构建顶点连接图（使用坐标字符串作为键）
      connections = {}
      edges.each do |edge|
        start_pt = edge.start.position
        end_pt = edge.end.position
        
        start_key = "#{start_pt.x.round(6)},#{start_pt.y.round(6)},#{start_pt.z.round(6)}"
        end_key = "#{end_pt.x.round(6)},#{end_pt.y.round(6)},#{end_pt.z.round(6)}"
        
        connections[start_key] ||= { point: start_pt, neighbors: [] }
        connections[start_key][:neighbors] << { point: end_pt, key: end_key }
        
        connections[end_key] ||= { point: end_pt, neighbors: [] }
        connections[end_key][:neighbors] << { point: start_pt, key: start_key }
      end
      
      # 从任意一个顶点开始遍历
      first_key = connections.keys.first
      start_vertex = connections[first_key][:point]
      sorted_vertices = [start_vertex]
      current_key = first_key
      visited_edges = Set.new
      
      while sorted_vertices.length < connections.keys.length
        # 找到下一个未访问的连接顶点
        next_data = nil
        connections[current_key][:neighbors].each do |neighbor_data|
          # 检查这条边是否已访问（使用坐标字符串组合作为键）
          edge_key = [current_key, neighbor_data[:key]].sort.join('_')
          unless visited_edges.include?(edge_key)
            visited_edges.add(edge_key)
            next_data = neighbor_data
            break
          end
        end
        
        break unless next_data
        
        sorted_vertices << next_data[:point]
        current_key = next_data[:key]
      end
      
      sorted_vertices
    end

    # 按连接顺序排序顶点（考虑边线组的变换）
    def self.sort_vertices_by_connection_with_transform(edges, transform)
      return [] if edges.empty?

      # 构建顶点连接图（使用坐标字符串作为键）
      connections = {}
      edges.each do |edge|
        # 将边线顶点从边线组坐标系转换到组件局部坐标系
        start_pt = edge.start.position.transform(transform)
        end_pt = edge.end.position.transform(transform)

        start_key = "#{start_pt.x.round(6)},#{start_pt.y.round(6)},#{start_pt.z.round(6)}"
        end_key = "#{end_pt.x.round(6)},#{end_pt.y.round(6)},#{end_pt.z.round(6)}"

        connections[start_key] ||= { point: start_pt, neighbors: [] }
        connections[start_key][:neighbors] << { point: end_pt, key: end_key }

        connections[end_key] ||= { point: end_pt, neighbors: [] }
        connections[end_key][:neighbors] << { point: start_pt, key: start_key }
      end

      # 从任意一个顶点开始遍历
      first_key = connections.keys.first
      start_vertex = connections[first_key][:point]
      sorted_vertices = [start_vertex]
      current_key = first_key
      visited_edges = Set.new

      while sorted_vertices.length < connections.keys.length
        # 找到下一个未访问的连接顶点
        next_data = nil
        connections[current_key][:neighbors].each do |neighbor_data|
          # 检查这条边是否已访问（使用坐标字符串组合作为键）
          edge_key = [current_key, neighbor_data[:key]].sort.join('_')
          unless visited_edges.include?(edge_key)
            visited_edges.add(edge_key)
            next_data = neighbor_data
            break
          end
        end

        break unless next_data

        sorted_vertices << next_data[:point]
        current_key = next_data[:key]
      end

      sorted_vertices
    end

  end
end
