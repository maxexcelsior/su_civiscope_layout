# 编码：UTF-8

module CiviscopeLayout
  module Core
    
    # ==========================================
    # 右键菜单功能
    # ==========================================
    
    # 注册右键菜单处理器
    UI.add_context_menu_handler do |menu|
      # 添加 CiviscopeLayout 主菜单
      submenu = menu.add_submenu("CiviscopeLayout")
      
      # 添加"重建用地红线"菜单项
      submenu.add_item("重建用地红线") { self.rebuild_site_boundary }
    end
    
    # ==========================================
    # 重建用地红线功能
    # ==========================================
    def self.rebuild_site_boundary
      model = Sketchup.active_model
      selection = model.selection
      
      # 1. 检查用户选择
      if selection.empty?
        UI.messagebox("请先选择地块边线组！")
        return
      end
      
      boundary_group = selection.first
      
      # 2. 验证是否是边线组
      unless boundary_group.is_a?(Sketchup::Group) && 
             boundary_group.get_attribute("dynamic_attributes", "site_boundary") == "true"
        UI.messagebox("请先选择地块边线组！\n\n提示：边线组是CIM地块组件内名为\"地块边线\"的组。")
        return
      end
      
      # 3. 找到所属的CIM地块组件
      # 边线组的 parent 是 ComponentDefinition，需要找到对应的实例
      definition = boundary_group.parent
      
      # 检查 parent 是否是 ComponentDefinition
      unless definition.is_a?(Sketchup::ComponentDefinition)
        UI.messagebox("无法找到所属的CIM地块组件！")
        return
      end
      
      # 找到该组件定义的第一个实例（CIM地块）
      site_instances = definition.instances
      if site_instances.empty?
        UI.messagebox("无法找到所属的CIM地块组件实例！")
        return
      end
      
      site_component = site_instances.first
      
      # 4. 开始操作
      model.start_operation("重建用地红线", true)
      
      begin
        # 5. 提取外轮廓边线（只提取不被两个面共享的边线）
        # 外轮廓边线：只属于一个面的边线
        # 边线坐标已经在组件局部坐标系中
        boundary_edges = definition.entities.grep(Sketchup::Edge).select do |edge|
          edge.faces.length == 1
        end
        
        if boundary_edges.empty?
          UI.messagebox("CIM地块内没有找到外轮廓边线，无法提取用地红线！")
          model.abort_operation
          return
        end
        
        # 6. 收集边线的端点坐标（组件局部坐标系）
        edge_points = boundary_edges.uniq.map do |edge|
          [edge.start.position, edge.end.position]
        end
        
        # 7. 删除原边线组
        boundary_group.erase!
        
        # 8. 创建新边线组
        new_boundary_group = definition.entities.add_group
        new_boundary_group.name = "地块边线"
        new_boundary_group.set_attribute("dynamic_attributes", "site_boundary", "true")
        
        # 9. 添加边线到新边线组（使用组件局部坐标）
        edge_points.each do |p1, p2|
          new_boundary_group.entities.add_line(p1, p2)
        end
        
        # 10. 重置边线组的变换为单位矩阵（确保坐标轴与CIM地块一致）
        # 获取当前变换并使用逆变换重置
        current_tr = new_boundary_group.transformation
        inverse_tr = current_tr.inverse
        new_boundary_group.transform! inverse_tr
        
        model.commit_operation
        
        # 8. 更新选择（选中新边线组）
        selection.clear
        selection.add(new_boundary_group)
        
        # 9. 更新限高盒 overlay 数据（如果该地块已启用限高检测）
        id_str = self.get_short_id(site_component)
        if @overlay && @overlay.sites_data.key?(id_str)
          # 先删除旧数据，再重新添加
          @overlay.sites_data.delete(id_str)
          self.add_site_to_height_check(site_component)
          UI.start_timer(0, false) { Sketchup.active_model.active_view.refresh }
        end
        
        UI.messagebox("用地红线已重建完成！\n\n新边线组已创建，原边线组已删除。")
        
      rescue => e
        model.abort_operation
        UI.messagebox("重建用地红线时发生错误：\n#{e.message}")
      end
    end
    
  end
end