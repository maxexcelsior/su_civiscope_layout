# 编码：UTF-8
module CiviscopeLayout
  module Core
    
    def self.get_full_world_transform(entity)
      # 递归向上寻找最准确的世界坐标变换
      tr = entity.transformation
      parent = entity.parent
      
      # 向上不断寻找实例直到模型根目录
      while parent && parent.is_a?(Sketchup::ComponentDefinition)
        # 如果达到了模型根目录的定义，停止
        break if parent.is_a?(Sketchup::Model)
        
        # 寻找该定义的实例 (优先取第一个，通常 BP 组在模型中是唯一的逻辑实例)
        inst = parent.instances.first
        break unless inst
        
        # 矩阵累乘：父级变换 * 当前变换
        tr = inst.transformation * tr
        parent = inst.parent
      end
      tr
    end

    def self.bounds_overlap_2d?(b1, b2)
      return false if b1.min.x > b2.max.x || b2.min.x > b1.max.x
      return false if b1.min.y > b2.max.y || b2.min.y > b1.max.y
      true
    end

    def self.point_in_site_vertical?(global_pt, site)
      tr = CiviscopeLayout::Core.get_full_world_transform(site)
      tr_inv = tr.inverse
      local_pt = global_pt.transform(tr_inv)
      
      global_pt2 = global_pt + Geom::Vector3d.new(0, 0, -1)
      local_pt2 = global_pt2.transform(tr_inv)
      local_vec = local_pt.vector_to(local_pt2)
      return false unless local_vec.valid?
      
      line = [local_pt, local_vec]
      
      definition = site.is_a?(Sketchup::Group) ? site.definition : (site.respond_to?(:definition) ? site.definition : nil)
      return false unless definition
      
      definition.entities.grep(Sketchup::Face).each do |face|
        intersect_pt = Geom.intersect_line_plane(line, face.plane)
        next unless intersect_pt
        
        res = face.classify_point(intersect_pt)
        if [Sketchup::Face::PointInside, Sketchup::Face::PointOnFace, Sketchup::Face::PointOnEdge, Sketchup::Face::PointOnVertex].include?(res)
          return true
        end
      end
      false
    end

    def self.point_in_polygon_2d?(pt, poly_pts)
      inside = false
      j = poly_pts.length - 1
      poly_pts.each_with_index do |p_i, i|
        p_j = poly_pts[j]
        if ((p_i.y > pt.y) != (p_j.y > pt.y)) &&
           (pt.x < (p_j.x - p_i.x) * (pt.y - p_i.y) / (p_j.y - p_i.y) + p_i.x)
          inside = !inside
        end
        j = i
      end
      inside
    end

    def self.get_footprint_points(entity)
      tr = self.get_full_world_transform(entity)
      definition = entity.is_a?(Sketchup::Group) ? entity.definition : entity.definition
      face = definition.entities.grep(Sketchup::Face).find { |f| f.normal.z < -0.99 }
      
      # Fallback to bounds corners if no bottom face found
      unless face
        b = definition.bounds
        pts = [b.corner(0), b.corner(1), b.corner(3), b.corner(2)] 
      else
        pts = face.outer_loop.vertices.map { |v| v.position }
      end
      
      pts.map { |p| p.transform(tr) }
    end

    def self.is_bldg_nested?(b_child, b_parent)
      # Child must be at or above Parent's base
      return false if b_child.bounds.min.z < b_parent.bounds.min.z - 0.1
      
      # Quick bounds check
      b1 = b_child.bounds
      b2 = b_parent.bounds
      return false if b1.min.x < b2.min.x - 0.1 || b1.max.x > b2.max.x + 0.1
      return false if b1.min.y < b2.min.y - 0.1 || b1.max.y > b2.max.y + 0.1
      
      # Detailed Footprint check
      child_pts = self.get_footprint_points(b_child)
      parent_pts = self.get_footprint_points(b_parent)
      
      child_pts.all? { |pt| self.point_in_polygon_2d?(pt, parent_pts) }
    end

  end
end
