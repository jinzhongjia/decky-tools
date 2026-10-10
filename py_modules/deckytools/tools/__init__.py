"""已注册的工具。新增工具:实现 core.tool.Tool 子类并加入 TOOLS(前端 src/tools/ 同步注册)。"""

from .proton import ProtonTool

TOOLS = [ProtonTool]
